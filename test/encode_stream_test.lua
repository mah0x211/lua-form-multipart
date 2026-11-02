local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local errlib = require('error')
local errno = require('errno')

function testcase.encode_propagates_data_writer_errors()
    for _, case in ipairs({
        { fail_at = 2, prefix = '--b\r\n' },
        { fail_at = 3, prefix = '--b\r\nContent-Disposition: form-data; name="foo"\r\n\r\n' },
        { fail_at = 4, prefix = '--b\r\nContent-Disposition: form-data; name="foo"\r\n\r\nvalue' },
        { fail_at = 5, prefix = '--b\r\nContent-Disposition: form-data; name="foo"\r\n\r\nvalue\r\n' },
    }) do
        local chunks = {}
        local calls = 0
        local result, err = multipart.encode({ foo = { 'value' } }, 'b', {
            write = function(_, s)
                calls = calls + 1
                if calls == case.fail_at then return nil, 'write stopped' end
                chunks[#chunks + 1] = s
                return #s
            end,
            writefile = function() error('must not be reached') end,
        })
        assert.is_nil(result)
        assert.match(tostring(err), 'write stopped')
        assert.equal(table.concat(chunks), case.prefix)
        assert.equal(calls, case.fail_at)
    end
end

function testcase.encode_reports_missing_pathname()
    local file, _, pathname = assert(mkstemp('./missing_file_XXXXXX'))
    file:close()
    assert(os.remove(pathname))
    local result, err = multipart.encode({ foo = {
        { filename = 'missing.txt', pathname = pathname },
    } }, 'b')
    assert.is_nil(result)
    assert.not_nil(multipart.EENCODE)
    assert.equal(errlib.typeof(err), multipart.EENCODE)
    assert.not_nil(errlib.is(err, errno.ENOENT))
    assert.equal(errlib.is(err, errno.ENOENT).op, 'open')
    assert.match(tostring(err), 'failed to open file')
    assert.match(tostring(err), pathname)
    assert.match(tostring(err), 'foo')
end

function testcase.encode_reports_reads_from_write_only_files()
    local file, _, pathname = assert(mkstemp('./write_only_XXXXXX'))
    file:close()
    file = assert(io.open(pathname, 'w'))
    assert(file:write('content'))
    assert(file:seek('set', 0))
    local result, err = multipart.encode({ foo = {
        { filename = 'x.txt', file = file },
    } }, 'b')
    local state = io.type(file)
    file:close()
    os.remove(pathname)
    assert.is_nil(result)
    assert.not_nil(multipart.EENCODE)
    assert.equal(errlib.typeof(err), multipart.EENCODE)
    assert.not_nil(errlib.is(err, errno.EBADF))
    assert.equal(errlib.is(err, errno.EBADF).op, 'read')
    assert.match(tostring(err), 'failed to read file "x.txt" in "foo"')
    assert.equal(state, 'file')
end
