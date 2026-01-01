using DaemonMode
using Test
using Sockets

# Try to load Revise, but skip tests if not available
const REVISE_AVAILABLE = try
    using Revise
    true
catch
    false
end

# Create a temporary test package for Revise testing
function setup_test_package(dir)
    pkg_dir = joinpath(dir, "TestRevisePackage")
    src_dir = joinpath(pkg_dir, "src")
    mkpath(src_dir)

    # Create Project.toml
    open(joinpath(pkg_dir, "Project.toml"), "w") do f
        write(f, """
        name = "TestRevisePackage"
        uuid = "12345678-1234-1234-1234-123456789abc"
        version = "0.1.0"

        [compat]
        julia = "1.4"
        """)
    end

    # Create initial working module
    open(joinpath(src_dir, "TestRevisePackage.jl"), "w") do f
        write(f, """
        module TestRevisePackage

        export greet

        function greet(name::String)
            return "Hello, \$(name)!"
        end

        end # module
        """)
    end

    return pkg_dir
end

function introduce_syntax_error(pkg_dir)
    src_file = joinpath(pkg_dir, "src", "TestRevisePackage.jl")
    open(src_file, "w") do f
        write(f, """
        module TestRevisePackage

        export greet

        function greet(name::String)
            return "Hello, \$(name)!"
        # Missing end here - syntax error!

        end # module
        """)
    end
end

function fix_syntax_error(pkg_dir)
    src_file = joinpath(pkg_dir, "src", "TestRevisePackage.jl")
    open(src_file, "w") do f
        write(f, """
        module TestRevisePackage

        export greet

        function greet(name::String)
            return "Hello, \$(name)!"
        end

        end # module
        """)
    end
end

@testset "Revise Error Detection" begin
    if !REVISE_AVAILABLE
        @info "Skipping Revise error detection tests - Revise not available"
    else
        port = 3020

        @testset "No errors - no warning" begin
            mktempdir() do tmpdir
                pkg_dir = setup_test_package(tmpdir)

                # Create a test script that loads the package
                test_script = joinpath(tmpdir, "test_script.jl")
                open(test_script, "w") do f
                    write(f, """
                    push!(LOAD_PATH, "$(tmpdir)")
                    using TestRevisePackage
                    println(greet("World"))
                    """)
                end

                # Start server
                task = @async serve(port, async=false)
                sleep(2)  # Give server time to start

                buffer = IOBuffer()
                runfile(test_script, output=buffer, port=port)
                output = String(take!(buffer))

                # Should not contain warning
                @test !occursin("WARNING: Revise encountered errors", output)
                @test occursin("Hello, World!", output)

                sendExitCode(port)
                wait(task)
            end
        end

        @testset "Syntax error - warning displayed" begin
            mktempdir() do tmpdir
                pkg_dir = setup_test_package(tmpdir)

                # Create initial test script
                test_script = joinpath(tmpdir, "test_script.jl")
                open(test_script, "w") do f
                    write(f, """
                    push!(LOAD_PATH, "$(tmpdir)")
                    using TestRevisePackage
                    println(greet("World"))
                    """)
                end

                # Start server
                task = @async serve(port + 1, async=false)
                sleep(2)

                # First run - should work
                buffer = IOBuffer()
                runfile(test_script, output=buffer, port=port + 1)
                output = String(take!(buffer))
                @test occursin("Hello, World!", output)

                # Introduce syntax error
                introduce_syntax_error(pkg_dir)
                sleep(0.5)  # Give Revise time to detect the change

                # Second run - should show warning but still use cached code
                buffer = IOBuffer()
                runfile(test_script, output=buffer, port=port + 1)
                output = String(take!(buffer))

                # Remove ANSI escape codes for easier testing
                output_clean = replace(output, r"\e\[[0-9;]*[a-zA-Z]" => "")

                @test occursin("WARNING: Revise encountered errors", output_clean)
                @test occursin("TestRevisePackage", output_clean)
                @test occursin("Hello, World!", output_clean)  # Still works with cached code

                sendExitCode(port + 1)
                wait(task)
            end
        end

        @testset "Error correction - warning disappears" begin
            mktempdir() do tmpdir
                pkg_dir = setup_test_package(tmpdir)

                test_script = joinpath(tmpdir, "test_script.jl")
                open(test_script, "w") do f
                    write(f, """
                    push!(LOAD_PATH, "$(tmpdir)")
                    using TestRevisePackage
                    println(greet("World"))
                    """)
                end

                task = @async serve(port + 2, async=false)
                sleep(2)

                # First run - working
                buffer = IOBuffer()
                runfile(test_script, output=buffer, port=port + 2)

                # Introduce error
                introduce_syntax_error(pkg_dir)
                sleep(0.5)

                # Run with error
                buffer = IOBuffer()
                runfile(test_script, output=buffer, port=port + 2)
                output_with_error = String(take!(buffer))
                output_clean = replace(output_with_error, r"\e\[[0-9;]*[a-zA-Z]" => "")
                @test occursin("WARNING: Revise encountered errors", output_clean)

                # Fix error
                fix_syntax_error(pkg_dir)
                sleep(0.5)

                # Run after fix - warning should be gone
                buffer = IOBuffer()
                runfile(test_script, output=buffer, port=port + 2)
                output_fixed = String(take!(buffer))
                output_clean = replace(output_fixed, r"\e\[[0-9;]*[a-zA-Z]" => "")

                @test !occursin("WARNING: Revise encountered errors", output_clean)
                @test occursin("Hello, World!", output_clean)

                sendExitCode(port + 2)
                wait(task)
            end
        end

        @testset "Persistent errors - warning on multiple runs" begin
            mktempdir() do tmpdir
                pkg_dir = setup_test_package(tmpdir)

                test_script = joinpath(tmpdir, "test_script.jl")
                open(test_script, "w") do f
                    write(f, """
                    push!(LOAD_PATH, "$(tmpdir)")
                    using TestRevisePackage
                    println(greet("World"))
                    """)
                end

                task = @async serve(port + 3, async=false)
                sleep(2)

                # First run - working
                runfile(test_script, output=IOBuffer(), port=port + 3)

                # Introduce error
                introduce_syntax_error(pkg_dir)
                sleep(0.5)

                # Run multiple times - should show warning each time
                for i in 1:3
                    buffer = IOBuffer()
                    runfile(test_script, output=buffer, port=port + 3)
                    output = String(take!(buffer))
                    output_clean = replace(output, r"\e\[[0-9;]*[a-zA-Z]" => "")
                    @test occursin("WARNING: Revise encountered errors", output_clean)
                end

                sendExitCode(port + 3)
                wait(task)
            end
        end
    end
end
