using TestItemRunner

@run_package_tests filter = ti -> isempty(ARGS) || any(occursin(pat, ti.filename) for pat in ARGS)
