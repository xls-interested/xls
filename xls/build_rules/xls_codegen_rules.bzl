# Copyright 2021 The XLS Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
This module contains codegen-related build rules for XLS.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load(
    "//xls/build_rules:xls_common_rules.bzl",
    "append_default_to_args",
    "args_to_string",
    "get_output_filename_value",
    "get_runfiles_for_xls",
    "get_transitive_built_files_for_xls",
    "is_args_valid",
    "split_filename",
)
load("//xls/build_rules:xls_config_rules.bzl", "CONFIG")
load("//xls/build_rules:xls_ir_rules.bzl", "xls_ir_common_attrs")
load("//xls/build_rules:xls_providers.bzl", "CodegenInfo", "OptIRInfo")
load(
    "//xls/build_rules:xls_toolchains.bzl",
    "get_executable_from",
    "get_runfiles_from",
    "get_xls_toolchain_info",
    "xls_toolchain_attr",
)

_DEFAULT_CODEGEN_ARGS = {
    "delay_model": "unit",
    "use_system_verilog": "True",
}

_SYSTEM_VERILOG_FILE_EXTENSION = "sv"
_VERILOG_FILE_EXTENSION = "v"
_SIGNATURE_TEXTPROTO_FILE_EXTENSION = ".sig.textproto"
_SCHEDULE_TEXTPROTO_FILE_EXTENSION = ".schedule.textproto"
_VERILOG_LINE_MAP_TEXTPROTO_FILE_EXTENSION = ".verilog_line_map.textproto"
_BLOCK_IR_FILE_EXTENSION = ".block.ir"

xls_ir_verilog_attrs = {
    "codegen_args": attr.string_dict(
        doc = "Arguments of the codegen tool. For details on the arguments, " +
              "refer to the codegen_main application at " +
              "//xls/tools/codegen_main.cc.",
    ),
    "verilog_file": attr.output(
        doc = "The filename of Verilog file generated. The filename must " +
              "have a " + _VERILOG_FILE_EXTENSION + " extension.",
        mandatory = True,
    ),
    "module_sig_file": attr.output(
        doc = "The filename of module signature of the generated Verilog " +
              "file. If not specified, the basename of the Verilog file " +
              "followed by a " + _SIGNATURE_TEXTPROTO_FILE_EXTENSION + " " +
              "extension is used.",
    ),
    "schedule_file": attr.output(
        doc = "The filename of schedule of the generated Verilog file." +
              "If not specified, the basename of the Verilog file followed " +
              "by a " + _SCHEDULE_TEXTPROTO_FILE_EXTENSION + " extension is " +
              "used.",
    ),
    "verilog_line_map_file": attr.output(
        doc = "The filename of line map for the generated Verilog file." +
              "If not specified, the basename of the Verilog file followed " +
              "by a " + _VERILOG_LINE_MAP_TEXTPROTO_FILE_EXTENSION + " extension is " +
              "used.",
    ),
    "block_ir_file": attr.output(
        doc = "The filename of block-level IR file generated during codegen. " +
              "If not specified, the basename of the Verilog file followed " +
              "by a " + _BLOCK_IR_FILE_EXTENSION + " extension is " +
              "used.",
    ),
}

def _is_combinational_generator(arguments):
    """Returns True, if "generator" is "combinational". Otherwise, returns False.

    Args:
      arguments: The list of arguments.
    Returns:
      Returns True, if "generator" is "combinational". Otherwise, returns False.
    """
    return arguments.get("generator", "") == "combinational"

def append_xls_ir_verilog_generated_files(args, basename, arguments):
    """Returns a dictionary of arguments appended with filenames generated by the 'xls_ir_verilog' rule.

    Args:
      args: A dictionary of arguments.
      basename: The file basename.
      arguments: The codegen arguments.

    Returns:
      Returns a dictionary of arguments appended with filenames generated by the 'xls_ir_verilog' rule.
    """
    args.setdefault(
        "module_sig_file",
        basename + _SIGNATURE_TEXTPROTO_FILE_EXTENSION,
    )
    args.setdefault(
        "block_ir_file",
        basename + _BLOCK_IR_FILE_EXTENSION,
    )
    if not _is_combinational_generator(arguments):
        args.setdefault(
            "schedule_file",
            basename + _SCHEDULE_TEXTPROTO_FILE_EXTENSION,
        )
    args.setdefault(
        "verilog_line_map_file",
        basename + _VERILOG_LINE_MAP_TEXTPROTO_FILE_EXTENSION,
    )
    return args

def get_xls_ir_verilog_generated_files(args, arguments):
    """Returns a list of filenames generated by the 'xls_ir_verilog' rule found in 'args'.

    Args:
      args: A dictionary of arguments.
      arguments: The codegen arguments.

    Returns:
      Returns a list of filenames generated by the 'xls_ir_verilog' rule found in 'args'.
    """
    generated_files = [
        args.get("module_sig_file"),
        args.get("block_ir_file"),
        args.get("verilog_line_map_file"),
    ]
    if not _is_combinational_generator(arguments):
        generated_files.append(args.get("schedule_file"))
    return generated_files

def validate_verilog_filename(verilog_filename, use_system_verilog):
    """Validate verilog filename.

    Args:
      verilog_filename: The verilog filename to validate.
      use_system_verilog: Whether to validate the file name as system verilog or not.

    Produces a failure if the verilog filename does not have a basename or a
    valid extension.
    """

    if (use_system_verilog and
        split_filename(verilog_filename)[1] != _SYSTEM_VERILOG_FILE_EXTENSION):
        fail("SystemVerilog filename must contain the '%s' extension." %
             _SYSTEM_VERILOG_FILE_EXTENSION)

    if (not use_system_verilog and
        split_filename(verilog_filename)[1] != _VERILOG_FILE_EXTENSION):
        fail("Verilog filename must contain the '%s' extension." %
             _VERILOG_FILE_EXTENSION)

def xls_ir_verilog_impl(ctx, src):
    """The core implementation of the 'xls_ir_verilog' rule.

    Generates a Verilog file, module signature file, block file, Verilog line
    map, and schedule file.

    Args:
      ctx: The current rule's context object.
      src: The source file.

    Returns:
      A tuple with the following elements in the order presented:
        1. The CodegenInfo provider
        1. The list of built files.
        1. The runfiles.
    """
    codegen_tool = get_executable_from(get_xls_toolchain_info(ctx).codegen_tool)
    my_generated_files = []

    # default arguments
    codegen_args = append_default_to_args(
        ctx.attr.codegen_args,
        _DEFAULT_CODEGEN_ARGS,
    )

    # parse arguments
    CODEGEN_FLAGS = (
        "clock_period_ps",
        "additional_input_delay_ps",
        "pipeline_stages",
        "delay_model",
        "io_constraints",
        "receives_first_sends_last",
        "top",
        "generator",
        "input_valid_signal",
        "output_valid_signal",
        "manual_load_enable_signal",
        "flop_inputs",
        "flop_inputs_kind",
        "flop_outputs",
        "flop_outputs_kind",
        "flop_single_value_channels",
        "add_idle_output",
        "module_name",
        "assert_format",
        "clock_margin_percent",
        "gate_format",
        "period_relaxation_percent",
        "reset",
        "reset_active_low",
        "reset_asynchronous",
        "reset_data_path",
        "use_system_verilog",
        "separate_lines",
        "streaming_channel_data_suffix",
        "streaming_channel_ready_suffix",
        "streaming_channel_valid_suffix",
        "assert_format",
        "gate_format",
        "smulp_format",
        "umulp_format",
        "ram_configurations",
        "gate_recvs",
        "array_index_bounds_checking",
    )

    is_args_valid(codegen_args, CODEGEN_FLAGS)
    my_args = args_to_string(codegen_args)
    uses_combinational_generator = _is_combinational_generator(codegen_args)

    # output filenames
    verilog_filename = ctx.attr.verilog_file.name
    use_system_verilog = codegen_args["use_system_verilog"].lower() == "true"
    validate_verilog_filename(verilog_filename, use_system_verilog)
    verilog_basename = split_filename(verilog_filename)[0]

    verilog_line_map_filename = get_output_filename_value(
        ctx,
        "verilog_line_map_file",
        verilog_basename + _VERILOG_LINE_MAP_TEXTPROTO_FILE_EXTENSION,
    )
    verilog_line_map_file = ctx.actions.declare_file(verilog_line_map_filename)
    my_generated_files.append(verilog_line_map_file)
    my_args += " --output_verilog_line_map_path={}".format(verilog_line_map_file.path)

    schedule_file = None
    if not uses_combinational_generator:
        # Pipeline generator produces a schedule artifact.
        schedule_filename = get_output_filename_value(
            ctx,
            "schedule_file",
            verilog_basename + _SCHEDULE_TEXTPROTO_FILE_EXTENSION,
        )

        schedule_file = ctx.actions.declare_file(schedule_filename)
        my_generated_files.append(schedule_file)
        my_args += " --output_schedule_path={}".format(schedule_file.path)

    verilog_file = ctx.actions.declare_file(verilog_filename)
    module_sig_filename = get_output_filename_value(
        ctx,
        "module_sig_file",
        verilog_basename + _SIGNATURE_TEXTPROTO_FILE_EXTENSION,
    )
    module_sig_file = ctx.actions.declare_file(module_sig_filename)
    my_generated_files += [verilog_file, module_sig_file]
    my_args += " --output_verilog_path={}".format(verilog_file.path)
    my_args += " --output_signature_path={}".format(module_sig_file.path)
    block_ir_filename = get_output_filename_value(
        ctx,
        "block_ir_file",
        verilog_basename + _BLOCK_IR_FILE_EXTENSION,
    )
    block_ir_file = ctx.actions.declare_file(block_ir_filename)
    my_args += " --output_block_ir_path={}".format(block_ir_file.path)
    my_generated_files.append(block_ir_file)

    # Get runfiles
    codegen_tool_runfiles = get_runfiles_from(
        get_xls_toolchain_info(ctx).codegen_tool,
    )
    runfiles = get_runfiles_for_xls(ctx, [codegen_tool_runfiles], [src])

    ctx.actions.run_shell(
        outputs = my_generated_files,
        tools = [codegen_tool],
        inputs = runfiles.files,
        command = "{} {} {}".format(
            codegen_tool.path,
            src.path,
            my_args,
        ),
        mnemonic = "Codegen",
        progress_message = "Building Verilog file: %s" % (verilog_file.path),
    )
    return [
        CodegenInfo(
            verilog_file = verilog_file,
            module_sig_file = module_sig_file,
            verilog_line_map_file = verilog_line_map_file,
            schedule_file = schedule_file,
            block_ir_file = block_ir_file,
            delay_model = codegen_args.get("delay_model"),
            top = codegen_args.get("module_name", codegen_args.get("top")),
            pipeline_stages = codegen_args.get("pipeline_stages"),
            clock_period_ps = codegen_args.get("clock_period_ps"),
        ),
        my_generated_files,
        runfiles,
    ]

def _xls_ir_verilog_impl_wrapper(ctx):
    """The implementation of the 'xls_ir_verilog' rule.

    Wrapper for xls_ir_verilog_impl. See: xls_ir_verilog_impl.

    Args:
      ctx: The current rule's context object.
    Returns:
      CodegenInfo provider
      DefaultInfo provider
    """
    codegen_info, built_files_list, runfiles = xls_ir_verilog_impl(
        ctx,
        ctx.file.src,
    )

    return [
        codegen_info,
        DefaultInfo(
            files = depset(
                direct = built_files_list,
                transitive = get_transitive_built_files_for_xls(
                    ctx,
                    [ctx.attr.src],
                ),
            ),
            runfiles = runfiles,
        ),
    ]

xls_ir_verilog = rule(
    doc = """A build rule that generates a Verilog file from an IR file.

Example:

    ```
    xls_ir_verilog(
        name = "a_verilog",
        src = "a.ir",
        codegen_args = {
            "pipeline_stages": "1",
            ...
        },
    )
    ```
    """,
    implementation = _xls_ir_verilog_impl_wrapper,
    attrs = dicts.add(
        xls_ir_common_attrs,
        xls_ir_verilog_attrs,
        CONFIG["xls_outs_attrs"],
        xls_toolchain_attr,
    ),
)

def _xls_benchmark_verilog_impl(ctx):
    """Implementation of the 'xls_benchmark_verilog' rule.

    Computes and prints various metrics about a Verilog target.

    Args:
      ctx: The current rule's context object.
    Returns:
      DefaultInfo provider
    """
    benchmark_codegen_tool = get_executable_from(
        get_xls_toolchain_info(ctx).benchmark_codegen_tool,
    )
    codegen_info = ctx.attr.verilog_target[CodegenInfo]
    opt_ir_info = ctx.attr.verilog_target[OptIRInfo]
    if not codegen_info.top:
        fail("Verilog target '%s' does not provide a top value" %
             ctx.attr.verilog_target.label.name)
    cmd = "{tool} {opt_ir} {block_ir} {verilog} --top={top}".format(
        opt_ir = opt_ir_info.opt_ir_file.short_path,
        verilog = codegen_info.verilog_file.short_path,
        top = codegen_info.top,
        tool = benchmark_codegen_tool.short_path,
        block_ir = codegen_info.block_ir_file.short_path,
    )
    if codegen_info.delay_model:
        cmd += " --delay_model={}".format(codegen_info.delay_model)
    if codegen_info.pipeline_stages:
        cmd += " --pipeline_stages={}".format(codegen_info.pipeline_stages)
    if codegen_info.clock_period_ps:
        cmd += " --clock_period_ps={}".format(codegen_info.clock_period_ps)
    executable_file = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Get runfiles
    benchmark_codegen_tool_runfiles = get_runfiles_from(
        get_xls_toolchain_info(ctx).benchmark_codegen_tool,
    )
    runfiles = get_runfiles_for_xls(
        ctx,
        [benchmark_codegen_tool_runfiles],
        [
            opt_ir_info.opt_ir_file,
            codegen_info.block_ir_file,
            codegen_info.verilog_file,
        ],
    )

    ctx.actions.write(
        output = executable_file,
        content = "\n".join([
            "#!/usr/bin/env bash",
            "set -e",
            cmd,
            "exit 0",
        ]),
        is_executable = True,
    )
    return [
        DefaultInfo(
            runfiles = runfiles,
            files = depset(
                direct = [executable_file],
                transitive = get_transitive_built_files_for_xls(
                    ctx,
                    [ctx.attr.verilog_target],
                ),
            ),
            executable = executable_file,
        ),
    ]

xls_benchmark_verilog_attrs = {
    "verilog_target": attr.label(
        doc = "The verilog target to benchmark.",
        providers = [CodegenInfo],
    ),
}

xls_benchmark_verilog = rule(
    doc = """Computes and prints various metrics about a Verilog target.

Example:
    ```
    xls_benchmark_verilog(
        name = "a_benchmark",
        verilog_target = "a_verilog_target",
    )
    ```
    """,
    implementation = _xls_benchmark_verilog_impl,
    attrs = dicts.add(xls_benchmark_verilog_attrs, xls_toolchain_attr),
    executable = True,
)
