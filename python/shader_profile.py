from collections import namedtuple
from datetime import datetime

import argparse
import csv
import json
import multiprocessing as mp
import os
import subprocess as sp


_SHADER_TYPE_MAP = {
    '.vert': 'vertex',
    '.frag': 'fragment',
    '.comp': 'compute'
}

_SHADER_EXEC_PATHS = ['total_cycles', 'longest_path_cycles', 'shortest_path_cycles']

_FIELD_LABEL_MAP = {
    'shader_name': 'Name',
    'shader_type': 'Type',
    'shader_variant': 'Variant',
    'shader_exec_path': 'Exec Path',

    'arith_fma': 'FMA',
    'arith_cvt': 'CVT',
    'arith_sfu': 'SFU',
    'load_store': 'LS',
    'varying': 'V',
    'texture': 'T',
    'shader_bounds': 'Bounds',

    'work_registers_used': 'Work Registers',
    'uniform_registers_used': 'Uniform Registers',
    'has_stack_spilling': 'Stack Spilling',
    'stack_spill_bytes': 'Spill Bytes',
    'fp16_arithmetic': 'FP16 Arithmetic',
    'error_log': 'Error'
}


class ShaderCompileResult:

    def __init__(self, filepath) -> None:
        _, ext = os.path.splitext(filepath)

        self.shader_name = os.path.basename(filepath)
        self.shader_type = _SHADER_TYPE_MAP[ext]
        self.shader_variant = 'N/A'
        self.shader_exec_path = 'unknown'
        self.arith_fma = 0
        self.arith_cvt = 0
        self.arith_sfu = 0
        self.load_store = 0
        self.varying = 0
        self.texture = 0
        self.shader_bounds = 'N/A'
        self.work_registers_used = 0
        self.uniform_registers_used = 0
        self.has_stack_spilling = False
        self.stack_spill_bytes = 0
        self.fp16_arithmetic = 0
        self.error_log = None

    def write_to_csv_dict(self, csv_writer):
        csv_writer.writerow(self.__dict__)


def exec_malioc(filepath):
    """Execute Mali offline compiler and return json format string."""

    _, ext = os.path.splitext(filepath)
    if ext not in _SHADER_TYPE_MAP:
        raise NotImplementedError(f'Not support shader type: {ext}')

    shader_type = _SHADER_TYPE_MAP[ext]
    cmd = f'malioc --{shader_type} --format json {filepath}'

    try:
        result = sp.check_output(cmd, stderr=sp.STDOUT).decode('utf-8')
    except sp.CalledProcessError as e:
        # The exit code would be non-zero when there are any shader compile errors.
        # Thus we have to return output from exception here.
        if e.returncode != 1:
            raise e

        result = e.output.decode('utf-8')

    return result


def write_compile_result_to_csv(shader_compile_result, csv_writer):
    """Append compiler result to csv_writer.

    Args:
        shader_compiler_result: namedtuple of the json object from Mali offline compile result.
        csv_writer: csv dictionary writer with keys from _FIELD_LABEL_MAP.
    """

    print(f'Processing {shader_compile_result.filename}')
    result = ShaderCompileResult(shader_compile_result.filename)

    # If it's failed to compile shader, we append the error messages at the end.
    if hasattr(shader_compile_result, 'errors'):
        result.error_log = '\n'.join(shader_compile_result.errors)
        if csv_writer:
            result.write_to_csv_dict(csv_writer)
        return

    # Vertex shader has 'position' and 'varying' variants; while fragment only has one type.
    for shader_variant in shader_compile_result.variants:
        for shader_exec_path in _SHADER_EXEC_PATHS:
            result.shader_variant = shader_variant.name
            result.shader_exec_path = shader_exec_path

            perf_result = getattr(shader_variant.performance, shader_exec_path)
            pipelines = shader_variant.performance.pipelines
            for idx, pipe_name in enumerate(pipelines):
                setattr(result, pipe_name, perf_result.cycle_count[idx])

            bound_pipelines = [_FIELD_LABEL_MAP[x] for x in perf_result.bound_pipelines if x]
            result.shader_bounds = ','.join(bound_pipelines)

            for idx, props in enumerate(shader_variant.properties):
                setattr(result, props.name, props.value)

            if csv_writer:
                result.write_to_csv_dict(csv_writer)


def _get_shader_files(folder):
    result = []

    for filename in os.listdir(folder):
        filepath = os.path.join(folder, filename)
        if not os.path.isfile(filepath):
            continue

        _, ext = os.path.splitext(filename)
        if ext in _SHADER_TYPE_MAP:
            result.append(filepath)

    return result


def _get_time_token():
    return datetime.now().strftime('%Y%m%d_%H%M%S')


def custom_json_decoder(d):
    return namedtuple('CompileResult', d.keys())(*d.values())


def generate_shader_profile(shader_folder, output_dir, process_count=4):

    shader_file_list = _get_shader_files(shader_folder)
    if not shader_file_list:
        print(f'Can not find any shaders in {shader_folder}')
        return

    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    time_token = _get_time_token()
    report_csv_path = os.path.join(output_dir, f'malioc_report_{time_token}.csv')

    with open(report_csv_path, 'w', newline='') as csvfile:
        csv_writer = csv.DictWriter(csvfile, fieldnames=_FIELD_LABEL_MAP.keys())
        csv_writer.writerow(_FIELD_LABEL_MAP)

        with mp.Pool(process_count) as pool:
            for output_str in pool.imap(exec_malioc, shader_file_list):
                result_json = json.loads(output_str, object_hook=custom_json_decoder)
                # Since we invoke malioc for each shader file, thus the shaders array only contains one entity.
                # We could directly pop the item in the shaders array.
                shader_compile_result = result_json.shaders.pop()
                write_compile_result_to_csv(shader_compile_result, csv_writer)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Generate shader static profile from Mali offline compiler')
    parser.add_argument('shader_path', help='Directory of shader files')
    parser.add_argument('-j', '--job-count', type=int, default=4, help='Number of compiling jobs')
    parser.add_argument('-o', '--output', type=str, default='.', help='Output directory')
    args = parser.parse_args()

    generate_shader_profile(args.shader_path, args.output, args.job_count)
