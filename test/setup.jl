@testmodule TestHelpers begin
    export my_add, my_sleep, bad_job

    function my_add(x, y)
        x + y
    end

    function my_sleep(n::Int)
        sleep(n)
        return n
    end

    function bad_job()
        a = []
        return a[1]
    end
end
