package = "form-multipart"
version = "dev-1"
source = {
    url = "git+https://github.com/mah0x211/lua-form-multipart.git",
}
description = {
    summary = "encode/decode the multipart/form-data format.",
    homepage = "https://github.com/mah0x211/lua-form-multipart",
    license = "MIT/X11",
    maintainer = "Masatoshi Fukunaga",
}
dependencies = {
    "lua >= 5.1",
    "error >= 0.8.0",
    "isa >= 0.3.0",
    "gcfn >= 0.3.0",
    "mkstemp >= 0.2.0",
}
build = {
    type = "builtin",
    modules = {
        ["form.multipart"] = "lib/multipart.lua",
    },
}
