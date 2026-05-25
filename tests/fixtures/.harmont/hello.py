import harmont as hm


@hm.pipeline("hello")
def hello() -> hm.Step:
    return hm.sh("echo 'hello from harmont action test'", label="greet")
