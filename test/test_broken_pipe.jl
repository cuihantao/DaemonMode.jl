"""
Tests for broken pipe (EPIPE) handling when output is piped to commands like head/tail.

This test suite verifies that DaemonMode correctly handles the case where the client
closes the output pipe early (e.g., when piping to `head -n 10`), which previously
caused IOError (EPIPE) crashes in both server and client.
"""

using DaemonMode
using Test
using Sockets

function start_test_server(port)
    task = @async serve(port, async=false)
    sleep(1)
    return task
end

function stop_test_server(task, port)
    sendExitCode(port)
    wait(task)
end

@testset "Broken Pipe Handling" begin

    @testset "Large output without pipe (baseline)" begin
        port = 3100
        task = start_test_server(port)

        # Create test file with lots of output
        test_file = joinpath(@__DIR__, "test_pipe_large.jl")
        write(test_file, """
        for i in 1:100
            println("Line \$i: This is output line number \$i")
        end
        """)

        buffer = IOBuffer()
        try
            # Normal execution - should get all output
            exit_code = runfile(test_file, output=buffer, port=port)
            output = String(take!(buffer))
            lines = split(output, '\n', keepempty=false)

            @test exit_code == 0
            @test length(lines) == 100
            @test occursin("Line 1:", lines[1])
            @test occursin("Line 100:", lines[100])

        finally
            rm(test_file, force=true)
            stop_test_server(task, port)
        end
    end

    @testset "Exit code with error output" begin
        port = 3101
        task = start_test_server(port)

        # Test file that generates output then errors
        test_file = joinpath(@__DIR__, "test_pipe_error.jl")
        write(test_file, """
        for i in 1:50
            println("Line \$i")
        end
        error("Intentional error for testing")
        """)

        buffer = IOBuffer()
        try
            exit_code = runfile(test_file, output=buffer, port=port)
            @test exit_code == 1  # Should return error code

            output = String(take!(buffer))
            @test occursin("Line 1", output)
            @test occursin("Intentional error", output)

        finally
            rm(test_file, force=true)
            stop_test_server(task, port)
        end
    end

    @testset "Logging output handling" begin
        port = 3102
        task = start_test_server(port)

        # Create test file with logging (simulates Revise output)
        test_file = joinpath(@__DIR__, "test_pipe_logging.jl")
        write(test_file, """
        using Logging

        for i in 1:20
            @info "Processing iteration \$i"
            println("Output line \$i")
        end
        """)

        buffer = IOBuffer()
        try
            exit_code = runfile(test_file, output=buffer, port=port)
            @test exit_code == 0

            output = String(take!(buffer))
            # Should contain both log messages and regular output
            @test occursin("Output line 1", output)
            @test occursin("Output line 20", output)

        finally
            rm(test_file, force=true)
            stop_test_server(task, port)
        end
    end

    @testset "runexpr with large output" begin
        port = 3103
        task = start_test_server(port)

        expr = """
        for i in 1:50
            println("Expression line \$i")
        end
        """

        buffer = IOBuffer()
        try
            runexpr(expr, output=buffer, port=port)
            output = String(take!(buffer))
            lines = split(output, '\n', keepempty=false)

            @test length(lines) == 50
            @test occursin("Expression line 1", lines[1])
            @test occursin("Expression line 50", lines[50])

        finally
            stop_test_server(task, port)
        end
    end

    @testset "Multiple concurrent clients" begin
        port = 3104
        task = start_test_server(port)

        test_file = joinpath(@__DIR__, "test_pipe_multi.jl")
        write(test_file, """
        for i in 1:30
            println("Client output line \$i")
        end
        """)

        try
            # Run multiple clients sequentially (async server handles concurrency)
            for client_id in 1:3
                buffer = IOBuffer()
                exit_code = runfile(test_file, output=buffer, port=port)
                output = String(take!(buffer))

                @test exit_code == 0
                lines = split(output, '\n', keepempty=false)
                @test length(lines) == 30
            end

        finally
            rm(test_file, force=true)
            stop_test_server(task, port)
        end
    end

    if Sys.isunix()
        @testset "Shell pipe integration (head)" begin
            port = 3105
            task = start_test_server(port)

            test_file = joinpath(@__DIR__, "test_pipe_shell.jl")
            write(test_file, """
            for i in 1:100
                println("Shell test line \$i")
            end
            """)

            test_script = joinpath(@__DIR__, "test_pipe_shell.sh")
            project_dir = dirname(@__DIR__)
            write(test_script, """
            #!/bin/bash
            set -e
            julia --project="$project_dir" -e "using DaemonMode; exit(runfile(\\"$test_file\\", port=$port))" 2>&1 | head -15
            exit \${PIPESTATUS[0]}
            """)
            chmod(test_script, 0o755)

            try
                # Run through bash with actual pipe to head
                output = read(`$test_script`, String)
                lines = split(output, '\n', keepempty=false)

                # Should get first 15 lines from head
                @test length(lines) >= 10
                @test length(lines) <= 16
                @test occursin("Shell test line 1", lines[1])

                # Script should exit with code 0 (success)
                @test success(`$test_script`)

            finally
                rm(test_file, force=true)
                rm(test_script, force=true)
                stop_test_server(task, port)
            end
        end

        @testset "Shell pipe with error (head)" begin
            port = 3106
            task = start_test_server(port)

            test_file = joinpath(@__DIR__, "test_pipe_shell_error.jl")
            write(test_file, """
            for i in 1:50
                println("Line \$i")
            end
            error("Test error")
            """)

            test_script = joinpath(@__DIR__, "test_pipe_shell_error.sh")
            project_dir = dirname(@__DIR__)
            write(test_script, """
            #!/bin/bash
            julia --project="$project_dir" -e "using DaemonMode; exit(runfile(\\"$test_file\\", port=$port))" 2>&1 | head -10
            exit \${PIPESTATUS[0]}
            """)
            chmod(test_script, 0o755)

            try
                # Should return error even with pipe
                result = run(`$test_script`, wait=false)
                wait(result)
                @test result.exitcode == 1  # Error exit code preserved

            catch e
                # Expected - script exits with error code
                @test e isa ProcessFailedException
            finally
                rm(test_file, force=true)
                rm(test_script, force=true)
                stop_test_server(task, port)
            end
        end

        @testset "Pipe to tail (reads from end)" begin
            port = 3107
            task = start_test_server(port)

            test_file = joinpath(@__DIR__, "test_pipe_tail.jl")
            write(test_file, """
            for i in 1:100
                println("Tail test line \$i")
            end
            """)

            test_script = joinpath(@__DIR__, "test_pipe_tail.sh")
            project_dir = dirname(@__DIR__)
            write(test_script, """
            #!/bin/bash
            julia --project="$project_dir" -e "using DaemonMode; exit(runfile(\\"$test_file\\", port=$port))" 2>&1 | tail -10
            exit \${PIPESTATUS[0]}
            """)
            chmod(test_script, 0o755)

            try
                output = read(`$test_script`, String)
                lines = split(output, '\n', keepempty=false)

                # Should get last 10 lines
                @test length(lines) >= 9
                @test length(lines) <= 11

                # Should exit successfully
                @test success(`$test_script`)

            finally
                rm(test_file, force=true)
                rm(test_script, force=true)
                stop_test_server(task, port)
            end
        end

        @testset "Pipe through grep (partial read)" begin
            port = 3108
            task = start_test_server(port)

            test_file = joinpath(@__DIR__, "test_pipe_grep.jl")
            write(test_file, """
            for i in 1:100
                if i % 10 == 0
                    println("MATCH: Line \$i is divisible by 10")
                else
                    println("Line \$i")
                end
            end
            """)

            test_script = joinpath(@__DIR__, "test_pipe_grep.sh")
            project_dir = dirname(@__DIR__)
            write(test_script, """
            #!/bin/bash
            julia --project="$project_dir" -e "using DaemonMode; exit(runfile(\\"$test_file\\", port=$port))" 2>&1 | grep "MATCH"
            exit \${PIPESTATUS[0]}
            """)
            chmod(test_script, 0o755)

            try
                output = read(`$test_script`, String)
                lines = split(output, '\n', keepempty=false)

                # Should get 10 matching lines
                @test length(lines) == 10
                @test all(l -> occursin("MATCH", l), lines)

                # Should exit successfully
                @test success(`$test_script`)

            finally
                rm(test_file, force=true)
                rm(test_script, force=true)
                stop_test_server(task, port)
            end
        end
    else
        @test_skip "Shell pipe tests require Unix"
    end

end
