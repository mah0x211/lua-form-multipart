local testcase = require('testcase')
local assert = require('assert')
local mkstemp = require('mkstemp')
local multipart = require('form.multipart')
local files = {}

function testcase.after_each()
    for _, entry in ipairs(files) do
        if io.type(entry.file) == 'file' then
            entry.file:close()
        end
        os.remove(entry.pathname)
    end
    files = {}
end

function testcase.encode_ignores_supplied_disposition_case_insensitively()
    for _, key in ipairs({
        'Content-Disposition',
        'content-disposition',
        'CoNtEnT-DiSpOsItIoN',
    }) do
        local header = {
            [key] = { 'form-data; name="old-name"' },
            ['X-Test'] = { 'metadata' },
        }
        local encoded, err, timeout = multipart.encode({
            foo = {{
                header = header,
                data = 'bar',
            }},
        }, 'b')
        assert.is_nil(err)
        assert.is_nil(timeout)
        assert.equal(encoded, '--b\r\nX-Test: metadata\r\n' ..
                     'Content-Disposition: form-data; name="foo"\r\n\r\n' ..
                     'bar\r\n--b--')
        assert.equal(header, {
            [key] = { 'form-data; name="old-name"' },
            ['X-Test'] = { 'metadata' },
        })
    end
end

function testcase.encode_decoded_text_without_duplicate_disposition()
    local original = '--b\r\n' ..
                     'Content-Disposition: form-data; name="foo"\r\n\r\n' ..
                     'bar\r\n--b--'
    local form = assert(multipart.decode(original, 'b'))
    local encoded = assert(multipart.encode(form, 'b'))
    assert.equal(encoded, original)
    local decoded = assert(multipart.decode(encoded, 'b'))
    assert.equal(decoded.foo[1].data, 'bar')
    assert.equal(form.foo[1].header['content-disposition'], {
        'form-data; name="foo"',
    })
end

function testcase.encode_file_without_duplicate_disposition()
    local file, err, pathname = mkstemp(
        (os.getenv('TMPDIR') or '/tmp') .. '/multipart_header_XXXXXX')
    assert(file, err)
    files[#files + 1] = { file = file, pathname = pathname }
    assert(file:write('content'))
    assert(file:seek('set'))

    local header = {
        ['CONTENT-DISPOSITION'] = {
            'form-data; name="old-name"; filename="old.txt"',
        },
    }
    local encoded, encode_err, timeout = multipart.encode({
        upload = {{
            file = file,
            filename = 'new.txt',
            header = header,
        }},
    }, 'b')
    assert.is_nil(encode_err)
    assert.is_nil(timeout)
    local _, count = string.gsub(string.lower(encoded),
                                 'content%-disposition:', '')
    assert.equal(count, 1)
    assert.match(encoded,
                 'Content-Disposition: form-data; name="upload"; filename="new.txt"\r\n')
    assert.match(encoded, '\r\n\r\ncontent\r\n--b--')
    assert.equal(header, {
        ['CONTENT-DISPOSITION'] = {
            'form-data; name="old-name"; filename="old.txt"',
        },
    })
end
