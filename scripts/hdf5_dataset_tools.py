#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Iterable

import h5py


def copy_attrs(src: h5py.AttributeManager, dst: h5py.AttributeManager) -> None:
    for key, value in src.items():
        dst[key] = value


def demo_sort_key(name: str) -> tuple[int, str]:
    if name.startswith("demo_"):
        try:
            return int(name.split("_", 1)[1]), name
        except ValueError:
            pass
    return 10**9, name


def demo_names(data_group: h5py.Group) -> list[str]:
    return sorted(
        (str(key) for key in data_group.keys() if str(key).startswith("demo_")),
        key=demo_sort_key,
    )


def demo_index(name: str) -> int:
    if not name.startswith("demo_"):
        raise ValueError(f"非法 demo 名称: {name}")
    return int(name.split("_", 1)[1])


def infer_num_samples(demo_group: h5py.Group) -> int:
    for key in ("actions", "processed_actions"):
        if key in demo_group and isinstance(demo_group[key], h5py.Dataset) and demo_group[key].ndim >= 1:
            return int(demo_group[key].shape[0])
    return int(demo_group.attrs.get("num_samples", 0))


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def ensure_output_file(path: Path, *, overwrite: bool) -> None:
    ensure_parent(path)
    if not path.exists():
        return
    if not overwrite:
        raise FileExistsError(f"输出文件已存在: {path}")
    if path.is_dir():
        raise IsADirectoryError(f"输出文件路径是目录: {path}")
    path.unlink()


def ensure_output_dir(path: Path, *, overwrite: bool) -> None:
    if path.exists():
        if not overwrite:
            raise FileExistsError(f"输出目录已存在: {path}")
        if not path.is_dir():
            raise NotADirectoryError(f"输出目录路径不是目录: {path}")
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def copy_top_level_metadata(src: h5py.File, dst: h5py.File) -> None:
    copy_attrs(src.attrs, dst.attrs)
    for key in src.keys():
        if key in {"data", "mask"}:
            continue
        src.copy(key, dst)


def copy_data_attrs(src: h5py.File, dst_data: h5py.Group) -> None:
    if "data" not in src or not isinstance(src["data"], h5py.Group):
        raise KeyError(f"{src.filename} 缺少 /data 组")
    copy_attrs(src["data"].attrs, dst_data.attrs)


def write_mapping_csv(path: Path | None, rows: list[dict[str, str]]) -> None:
    if path is None:
        return
    ensure_parent(path)
    fieldnames = list(rows[0].keys()) if rows else ["current_trial", "current_demo"]
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def read_mapping_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def parse_trial_token(token: str) -> int:
    m = re.match(r"^trial[_-]?(\d+)$", token.strip(), re.IGNORECASE)
    if m:
        return int(m.group(1))
    if token.strip().isdigit():
        return int(token.strip())
    raise ValueError(f"无法解析 trial: {token}")


def current_demo_from_row(row: dict[str, str]) -> str:
    for key in ("current_demo", "merged_demo", "final_demo", "source_demo"):
        value = row.get(key)
        if value:
            return value
    raise KeyError(f"映射行缺少 demo 字段: {row}")


def decode_hdf5_string(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return str(value)


def iter_dataset_strings(dataset: h5py.Dataset) -> Iterable[str]:
    values = dataset[()]
    if getattr(values, "shape", ()) == ():
        yield decode_hdf5_string(values.item() if hasattr(values, "item") else values)
        return
    for value in values.reshape(-1):
        yield decode_hdf5_string(value)


def collect_rewritten_masks(src: h5py.File, name_map: dict[str, str]) -> dict[str, list[str]]:
    if "mask" not in src or not isinstance(src["mask"], h5py.Group):
        return {}
    masks: dict[str, list[str]] = {}
    for mask_name, obj in src["mask"].items():
        if not isinstance(obj, h5py.Dataset):
            continue
        rewritten: list[str] = []
        for old_name in iter_dataset_strings(obj):
            if old_name in name_map:
                rewritten.append(name_map[old_name])
        if rewritten:
            masks[str(mask_name)] = rewritten
    return masks


def merge_mask_maps(mask_maps: list[dict[str, list[str]]]) -> dict[str, list[str]]:
    merged: dict[str, list[str]] = {}
    for mask_map in mask_maps:
        for mask_name, names in mask_map.items():
            merged.setdefault(mask_name, []).extend(names)
    return merged


def write_masks(dst: h5py.File, masks: dict[str, list[str]]) -> None:
    if not masks:
        return
    mask_group = dst.create_group("mask")
    dtype = h5py.string_dtype(encoding="utf-8")
    for mask_name, names in sorted(masks.items()):
        sorted_names = sorted(dict.fromkeys(names), key=demo_sort_key)
        mask_group.create_dataset(mask_name, data=sorted_names, dtype=dtype)


def command_merge(args: argparse.Namespace) -> int:
    inputs = [Path(p).expanduser().resolve() for p in args.inputs]
    output = Path(args.output).expanduser().resolve()
    mapping_csv = Path(args.mapping_csv).expanduser().resolve() if args.mapping_csv else None
    source_labels = args.source_labels or []

    if len(inputs) < 1:
        raise ValueError("至少需要一个输入 HDF5")
    if source_labels and len(source_labels) != len(inputs):
        raise ValueError("--source_labels 数量必须与输入 HDF5 数量一致")
    for path in inputs:
        if not path.is_file():
            raise FileNotFoundError(f"输入 HDF5 不存在: {path}")

    ensure_output_file(output, overwrite=args.overwrite)
    rows: list[dict[str, str]] = []
    merged_masks: list[dict[str, list[str]]] = []
    total = 0
    next_demo_idx = 0

    with h5py.File(output, "w") as dst:
        with h5py.File(inputs[0], "r") as first:
            copy_top_level_metadata(first, dst)
            dst_data = dst.create_group("data")
            copy_data_attrs(first, dst_data)

        for source_order, input_path in enumerate(inputs):
            with h5py.File(input_path, "r") as src:
                src_data = src["data"]
                source_name_map: dict[str, str] = {}
                for old_demo in demo_names(src_data):
                    new_demo = f"demo_{next_demo_idx}"
                    src_data.copy(old_demo, dst_data, new_demo)
                    samples = infer_num_samples(dst_data[new_demo])
                    total += samples
                    source_file = str(source_labels[source_order]) if source_labels else str(input_path)
                    rows.append(
                        {
                            "current_trial": f"trial_{next_demo_idx}",
                            "current_demo": new_demo,
                            "source_order": str(source_order),
                            "source_file": source_file,
                            "source_demo": old_demo,
                            "source_trial": f"trial_{demo_index(old_demo)}",
                            "num_samples": str(samples),
                        }
                    )
                    source_name_map[old_demo] = new_demo
                    next_demo_idx += 1
                merged_masks.append(collect_rewritten_masks(src, source_name_map))

        dst_data.attrs["total"] = total
        write_masks(dst, merge_mask_maps(merged_masks))

    write_mapping_csv(mapping_csv, rows)
    print(f"[hdf5-tools] merged {len(inputs)} file(s), demos={next_demo_idx}, total={total}")
    print(f"[hdf5-tools] wrote hdf5: {output}")
    if mapping_csv is not None:
        print(f"[hdf5-tools] wrote mapping: {mapping_csv}")
    return 0


def format_bytes(size: int) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    value = float(size)
    for unit in units:
        if unit == "B":
            if value < 1024:
                return f"{size} B"
        elif value < 1024:
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} PB"


def command_check(args: argparse.Namespace) -> int:
    inputs = [Path(p).expanduser().resolve() for p in args.inputs]
    if args.min_bytes < 0:
        raise ValueError("--min_bytes 不能小于 0")

    for path in inputs:
        if not path.is_file():
            raise FileNotFoundError(f"HDF5 文件不存在: {path}")
        size = path.stat().st_size
        if size < args.min_bytes:
            raise ValueError(
                f"HDF5 文件过小，疑似未写完整: {path} "
                f"({size} bytes < {args.min_bytes} bytes)"
            )

        try:
            with h5py.File(path, "r") as f:
                demo_count = 0
                sample_total = 0
                if args.require_data:
                    if "data" not in f or not isinstance(f["data"], h5py.Group):
                        raise KeyError(f"{path} 缺少 /data 组")
                    data_group = f["data"]
                    demos = demo_names(data_group)
                    if args.require_demos and not demos:
                        raise ValueError(f"{path} 的 /data 下没有 demo_*")
                    demo_count = len(demos)
                    empty_demos: list[str] = []
                    for name in demos:
                        obj = data_group[name]
                        if not isinstance(obj, h5py.Group):
                            raise TypeError(f"{path} 中 /data/{name} 不是 group")
                        samples = infer_num_samples(obj)
                        if samples <= 0:
                            empty_demos.append(name)
                        sample_total += max(samples, 0)
                    if empty_demos:
                        shown = ", ".join(empty_demos[:10])
                        suffix = " ..." if len(empty_demos) > 10 else ""
                        raise ValueError(f"{path} 以下 demo 样本数为 0 或缺失: {shown}{suffix}")
        except OSError as exc:
            raise OSError(f"HDF5 无法打开，文件可能损坏或未写完整: {path} ({exc})") from exc

        details = f"size={format_bytes(size)}"
        if args.require_data:
            details += f", demos={demo_count}, samples={sample_total}"
        print(f"[hdf5-tools] checked ok: {path} ({details})")
    return 0


def command_init_map(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    source_file = str(Path(args.source_file).expanduser().resolve() if args.source_file else input_path)
    if not input_path.is_file():
        raise FileNotFoundError(f"输入 HDF5 不存在: {input_path}")

    rows: list[dict[str, str]] = []
    with h5py.File(input_path, "r") as src:
        for name in demo_names(src["data"]):
            idx = demo_index(name)
            rows.append(
                {
                    "current_trial": f"trial_{idx}",
                    "current_demo": name,
                    "source_order": "0",
                    "source_file": source_file,
                    "source_demo": name,
                    "source_trial": f"trial_{idx}",
                    "num_samples": str(infer_num_samples(src["data"][name])),
                }
            )
    write_mapping_csv(output, rows)
    print(f"[hdf5-tools] wrote map: {output}")
    return 0


def command_filter_map(args: argparse.Namespace) -> int:
    input_map = Path(args.input).expanduser().resolve()
    output_map = Path(args.output).expanduser().resolve()
    removed = {parse_trial_token(token) for token in args.remove_trials}
    rows = read_mapping_csv(input_map)

    kept: list[dict[str, str]] = []
    for row in rows:
        current_demo = current_demo_from_row(row)
        old_idx = demo_index(current_demo)
        if old_idx in removed:
            continue
        kept.append(row)

    rewritten: list[dict[str, str]] = []
    for new_idx, row in enumerate(kept):
        new_row = dict(row)
        new_row["current_trial"] = f"trial_{new_idx}"
        new_row["current_demo"] = f"demo_{new_idx}"
        rewritten.append(new_row)

    write_mapping_csv(output_map, rewritten)
    print(f"[hdf5-tools] filtered map: kept={len(rewritten)} removed={len(rows) - len(rewritten)}")
    print(f"[hdf5-tools] wrote map: {output_map}")
    return 0


def command_align_map(args: argparse.Namespace) -> int:
    input_map = Path(args.input).expanduser().resolve()
    input_hdf5 = Path(args.hdf5).expanduser().resolve()
    output_map = Path(args.output).expanduser().resolve()
    rows = read_mapping_csv(input_map)
    with h5py.File(input_hdf5, "r") as f:
        keep = set(demo_names(f["data"]))

    aligned: list[dict[str, str]] = []
    for row in rows:
        if current_demo_from_row(row) in keep:
            aligned.append(row)

    write_mapping_csv(output_map, aligned)
    print(f"[hdf5-tools] aligned map to hdf5: kept={len(aligned)} dropped={len(rows) - len(aligned)}")
    print(f"[hdf5-tools] wrote map: {output_map}")
    return 0


def load_episode_video_map(video_dir: Path) -> dict[str, Path]:
    map_path = video_dir / "episode_video_map.json"
    if not map_path.is_file():
        return {}
    payload = json.loads(map_path.read_text(encoding="utf-8"))
    mapping: dict[str, Path] = {}
    for row in payload:
        episode_name = str(row.get("final_episode_name", "")).strip()
        video_file = str(row.get("video_file", "")).strip()
        if episode_name and video_file:
            mapping[episode_name] = video_dir / video_file
    return mapping


def resolve_video(video_dir: Path, old_demo: str, video_map: dict[str, Path]) -> Path:
    old_idx = demo_index(old_demo)
    candidates = [
        video_map.get(old_demo),
        video_dir / f"trial_{old_idx}.mp4",
        video_dir / f"demo_{old_idx}.mp4",
    ]
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate
    raise FileNotFoundError(f"未找到 {old_demo} 对应视频: {video_dir}/trial_{old_idx}.mp4")


def write_episode_video_map(video_dir: Path, count: int) -> None:
    payload = [
        {
            "episode_index": i,
            "final_episode_name": f"demo_{i}",
            "video_file": f"trial_{i}.mp4",
        }
        for i in range(count)
    ]
    (video_dir / "episode_video_map.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def command_reindex(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    mapping_csv = Path(args.mapping_csv).expanduser().resolve() if args.mapping_csv else None
    source_mapping_csv = Path(args.source_mapping_csv).expanduser().resolve() if args.source_mapping_csv else None
    video_dir = Path(args.video_dir).expanduser().resolve() if args.video_dir else None
    output_video_dir = Path(args.output_video_dir).expanduser().resolve() if args.output_video_dir else None

    if not input_path.is_file():
        raise FileNotFoundError(f"输入 HDF5 不存在: {input_path}")
    if output_video_dir is not None and video_dir is None:
        raise ValueError("指定 --output_video_dir 时必须同时指定 --video_dir")
    if video_dir is not None and not video_dir.is_dir():
        raise NotADirectoryError(f"视频目录不存在: {video_dir}")

    ensure_output_file(output_path, overwrite=args.overwrite)
    if output_video_dir is not None:
        ensure_output_dir(output_video_dir, overwrite=args.overwrite)

    rows: list[dict[str, str]] = []
    source_rows_by_demo: dict[str, dict[str, str]] = {}
    if source_mapping_csv is not None:
        for row in read_mapping_csv(source_mapping_csv):
            source_rows_by_demo[current_demo_from_row(row)] = row
    total = 0

    with h5py.File(input_path, "r") as src, h5py.File(output_path, "w") as dst:
        copy_top_level_metadata(src, dst)
        dst_data = dst.create_group("data")
        copy_data_attrs(src, dst_data)

        src_data = src["data"]
        old_demos = demo_names(src_data)
        name_map: dict[str, str] = {}
        for new_idx, old_demo in enumerate(old_demos):
            new_demo = f"demo_{new_idx}"
            src_data.copy(old_demo, dst_data, new_demo)
            samples = infer_num_samples(dst_data[new_demo])
            total += samples
            row = {
                "final_trial": f"trial_{new_idx}",
                "final_demo": new_demo,
                "input_demo": old_demo,
                "input_trial": f"trial_{demo_index(old_demo)}",
                "num_samples": str(samples),
            }
            if old_demo in source_rows_by_demo:
                source_row = source_rows_by_demo[old_demo]
                row.update(
                    {
                        "source_order": source_row.get("source_order", ""),
                        "source_file": source_row.get("source_file", ""),
                        "source_demo": source_row.get("source_demo", ""),
                        "source_trial": source_row.get("source_trial", ""),
                    }
                )
            else:
                row.update(
                    {
                        "source_order": "",
                        "source_file": str(input_path),
                        "source_demo": old_demo,
                        "source_trial": f"trial_{demo_index(old_demo)}",
                    }
                )
            rows.append(row)
            name_map[old_demo] = new_demo

        dst_data.attrs["total"] = total
        write_masks(dst, collect_rewritten_masks(src, name_map))

    if output_video_dir is not None and video_dir is not None:
        video_map = load_episode_video_map(video_dir)
        for new_idx, row in enumerate(rows):
            src_video = resolve_video(video_dir, row["input_demo"], video_map)
            dst_video = output_video_dir / f"trial_{new_idx}.mp4"
            shutil.copy2(src_video, dst_video)
        write_episode_video_map(output_video_dir, len(rows))

    write_mapping_csv(mapping_csv, rows)
    print(f"[hdf5-tools] reindexed demos={len(rows)}, total={total}")
    print(f"[hdf5-tools] wrote hdf5: {output_path}")
    if output_video_dir is not None:
        print(f"[hdf5-tools] wrote videos: {output_video_dir}")
    if mapping_csv is not None:
        print(f"[hdf5-tools] wrote mapping: {mapping_csv}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="easim HDF5 merge/reindex helper.")
    sub = parser.add_subparsers(dest="command", required=True)

    merge = sub.add_parser("merge", help="合并多个 HDF5，并将 demo/trial 连续重编号。")
    merge.add_argument("inputs", nargs="+", help="输入 HDF5 文件。")
    merge.add_argument("--output", required=True, help="输出 HDF5。")
    merge.add_argument("--mapping_csv", default=None, help="输出 trial 映射表。")
    merge.add_argument("--source_labels", nargs="*", default=None, help="映射表中记录的原始源文件标签，数量需与输入一致。")
    merge.add_argument("--overwrite", action="store_true", help="允许覆盖输出 HDF5。")
    merge.set_defaults(func=command_merge)

    check = sub.add_parser("check", help="检查 HDF5 是否存在、大小正常、可打开并包含必要结构。")
    check.add_argument("inputs", nargs="+", help="输入 HDF5 文件。")
    check.add_argument("--min_bytes", type=int, default=2048, help="允许的最小文件大小，单位 bytes。")
    check.add_argument("--require_data", action="store_true", help="要求存在 /data 组。")
    check.add_argument("--require_demos", action="store_true", help="要求 /data 下至少存在一个 demo_*。")
    check.set_defaults(func=command_check)

    init_map = sub.add_parser("init-map", help="为单个 HDF5 生成 current_demo 到原始 trial 的映射表。")
    init_map.add_argument("--input", required=True, help="输入 HDF5。")
    init_map.add_argument("--output", required=True, help="输出映射 CSV。")
    init_map.add_argument("--source_file", default=None, help="映射表中记录的原始源文件路径。")
    init_map.set_defaults(func=command_init_map)

    filter_map = sub.add_parser("filter-map", help="剔除异常 trial 后同步更新映射表。")
    filter_map.add_argument("--input", required=True, help="输入映射 CSV。")
    filter_map.add_argument("--output", required=True, help="输出映射 CSV。")
    filter_map.add_argument("--remove_trials", nargs="+", required=True, help="已剔除的 trial。")
    filter_map.set_defaults(func=command_filter_map)

    align_map = sub.add_parser("align-map", help="按当前 HDF5 中存在的 demo 过滤映射表。")
    align_map.add_argument("--input", required=True, help="输入映射 CSV。")
    align_map.add_argument("--hdf5", required=True, help="参考 HDF5。")
    align_map.add_argument("--output", required=True, help="输出映射 CSV。")
    align_map.set_defaults(func=command_align_map)

    reindex = sub.add_parser("reindex", help="将单个 HDF5 和可选视频目录连续重编号。")
    reindex.add_argument("--input", required=True, help="输入 HDF5。")
    reindex.add_argument("--output", required=True, help="输出 HDF5。")
    reindex.add_argument("--video_dir", default=None, help="输入视频目录。")
    reindex.add_argument("--output_video_dir", default=None, help="输出视频目录。")
    reindex.add_argument("--mapping_csv", default=None, help="输出 trial 映射表。")
    reindex.add_argument("--source_mapping_csv", default=None, help="当前 HDF5 demo 到原始数据的映射 CSV。")
    reindex.add_argument("--overwrite", action="store_true", help="允许覆盖输出。")
    reindex.set_defaults(func=command_reindex)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[hdf5-tools] error: {exc}", file=sys.stderr)
        raise SystemExit(1)
