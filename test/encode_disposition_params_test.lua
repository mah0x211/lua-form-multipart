local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local files = {}

local function sourcefile()
    local file, err, pathname = mkstemp(
        (os.getenv('TMPDIR') or '/tmp') .. '/multipart_params_XXXXXX')
    assert(file, err)
    files[#files + 1] = { file = file, pathname = pathname }
    assert(file:write('content'))
    assert(file:seek('set'))
    return file
end

function testcase.after_each()
    for _, part in ipairs(files) do
        if part.gc then
            part.gc:disable()
        end
        if io.type(part.file) == 'file' then
            part.file:close()
        end
        os.remove(part.pathname)
    end
    files = {}
end

function testcase.encode_preserves_quoted_disposition_names()
    for _, name in ipairs({
        '', 'plain', 'with space', 'with\ttab', 'a"b', 'a\\b', '日本語',
    }) do
        local encoded = assert(multipart.encode({ [name] = { 'value' } }, 'b'))
        local form, err = multipart.decode(encoded, 'b')
        assert(form, err)
        assert.equal(form[name][1].name, name)
        assert.equal(form[name][1].data, 'value')
    end
end

function testcase.encode_preserves_quoted_disposition_filenames()
    local file = sourcefile()
    for _, filename in ipairs({
        '', 'plain.txt', 'with space.txt', 'with\ttab.txt', 'a"b.txt',
        'a\\b.txt', '日本語.txt',
    }) do
        assert(file:seek('set'))
        local encoded = assert(multipart.encode({
            upload = {{ file = file, filename = filename }},
        }, 'b'))
        local form, err = multipart.decode(encoded, 'b', {
            filetmpl = (os.getenv('TMPDIR') or '/tmp') .. '/multipart_decoded',
        })
        assert(form, err)
        local part = form.upload[1]
        files[#files + 1] = part
        assert.equal(part.filename, filename)
    end
end

function testcase.encode_rejects_control_bytes_in_disposition_names()
    local file = sourcefile()
    for _, c in ipairs({ '\0', '\1', '\8', '\10', '\13', '\31', '\127' }) do
        local name = 'a' .. c .. 'b'
        for _, parts in ipairs({
            { 'value' },
            {{ file = file, filename = 'x.txt' }},
        }) do
            local encoded, err, timeout = multipart.encode({ [name] = parts }, 'b')
            assert.is_nil(encoded)
            assert.is_nil(timeout)
            assert.equal(errlib.typeof(err), multipart.EENCODE)
            assert.not_nil(errlib.is(err, errno.EINVAL))
            assert.match(tostring(err), 'name contains a control character')
        end
    end
    assert.equal(io.type(file), 'file')
end

function testcase.encode_rejects_control_bytes_in_disposition_filenames()
    local file = sourcefile()
    for _, c in ipairs({ '\0', '\1', '\8', '\10', '\13', '\31', '\127' }) do
        local encoded, err, timeout = multipart.encode({
            upload = {{ file = file, filename = 'a' .. c .. 'b.txt' }},
        }, 'b')
        assert.is_nil(encoded)
        assert.is_nil(timeout)
        assert.equal(errlib.typeof(err), multipart.EENCODE)
        assert.not_nil(errlib.is(err, errno.EINVAL))
        assert.match(tostring(err), 'filename contains a control character')
    end
    assert.equal(io.type(file), 'file')
end
