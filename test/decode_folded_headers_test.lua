local testcase = require('testcase')
local assert = require('assert')
local errlib = require('error')
local errno = require('errno')
local multipart = require('form.multipart')
local uploads = {}

local function input_for(headers, body)
    return '--b\r\n' .. headers .. '\r\n\r\n' .. (body or 'value') .. '\r\n--b--'
end

local function reader(input, split)
    local pos = 1
    return {
        read = function(_, n)
            local last = math.min(#input, pos + n - 1)
            if split and pos <= split then last = math.min(last, split) end
            local s = input:sub(pos, last)
            pos = pos + #s
            if #s > 0 then return s end
        end,
    }
end

local headers = 'Content-Disposition: form-data;\r\n name="foo";\r\n\tcustom="a;\r\n b"\r\n' ..
    'Content-Type: text/plain;\r\n\tcharset=utf-8'

local function assert_folded_form(form, err)
    assert.is_nil(err)
    assert.equal(form.foo[1], {
        name = 'foo',
        params = { name = 'foo', custom = 'a; b' },
        data = 'value',
        header = {
            ['content-disposition'] = { 'form-data; name="foo";\tcustom="a; b"' },
            ['content-type'] = { 'text/plain;\tcharset=utf-8' },
        },
    })
end

function testcase.after_each()
    for _, part in ipairs(uploads) do
        part.file:close()
        os.remove(part.pathname)
    end
    uploads = {}
end

function testcase.decode_unfolds_supported_field_values()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        local input = input_for(headers):gsub('\r\n', newline)
        assert_folded_form(multipart.decode(input, 'b'))
        assert_folded_form(multipart.decode(reader(input), 'b', nil, nil, 1))
    end
end

function testcase.decode_preserves_folds_at_every_input_split()
    for _, newline in ipairs({ '\r\n', '\n' }) do
        local input = input_for(headers):gsub('\r\n', newline)
        for split = 1, #input - 1 do
            assert_folded_form(multipart.decode(reader(input, split), 'b'))
        end
    end
end

function testcase.decode_accepts_a_fold_after_colon_and_whitespace_only_continuations()
    local input = input_for('Content-Disposition:\r\n form-data;\r\n \t\r\n\tname="foo"')
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', nil, nil, 1)
        assert.is_nil(err)
        assert.equal(form.foo[1].params, { name = 'foo' })
        assert.equal(form.foo[1].data, 'value')
    end
end

function testcase.decode_ignores_folded_unsupported_fields_without_consuming_body()
    local payload = '\tContent-Type: this is body data'
    local input = input_for('X-Ignore:\r\n arbitrary: data\r\n\tmore data\r\n' ..
        'Content-Transfer-Encoding:\r\n base64\r\n' ..
        'Content-Disposition: form-data;\r\n name="foo"', payload)
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', nil, nil, 1)
        assert.is_nil(err)
        assert.equal(form.foo[1].data, payload)
        assert.equal(form.foo[1].header, {
            ['content-disposition'] = { 'form-data; name="foo"' },
        })
    end
end

function testcase.decode_rejects_orphan_continuations_and_folded_field_names()
    for _, invalid in ipairs({
        ' name="foo"',
        '\tname="foo"',
        ' \t',
        'Content-Dispo\r\n sition: form-data; name="foo"',
        'Content-Disposition\r\n : form-data; name="foo"',
        'Content-Disposition \r\n\t: form-data; name="foo"',
    }) do
        local input = input_for(invalid)
        for _, source in ipairs({ input, reader(input) }) do
            local form, err = multipart.decode(source, 'b', nil, nil, 1)
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.not_nil(errlib.is(err, errno.EINVAL))
        end
    end
end

function testcase.decode_rejects_duplicate_folded_disposition_fields()
    local input = input_for('Content-Disposition: form-data;\r\n name="foo"\r\n' ..
        'Content-Disposition:\r\n form-data; name="bar"')
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', nil, nil, 1)
        assert.is_nil(form)
        assert.not_nil(errlib.is(err, errno.EINVAL))
        assert.match(tostring(err), 'duplicate Content-Disposition header')
    end
end

function testcase.decode_preserves_errors_and_eof_while_resolving_folds()
    for _, prefix in ipairs({
        '--b\r\nContent-Disposition: form-data;',
        '--b\r\nContent-Disposition: form-data;\r',
        '--b\r\nContent-Disposition: form-data;\r\n',
        '--b\r\nContent-Disposition: form-data;\r\n ',
        '--b\r\nContent-Disposition: form-data;\r\n name="foo"\r\n',
    }) do
        for _, raises in ipairs({ false, true }) do
            local cause = errno.EIO:new('fold reader failed')
            local calls = 0
            local source = {
                read = function()
                    calls = calls + 1
                    if calls == 1 then return prefix end
                    assert.equal(calls, 2)
                    if raises then error(cause, 0) end
                    return nil, cause
                end,
            }
            local form, err = multipart.decode(source, 'b')
            assert.is_nil(form)
            assert.equal(errlib.typeof(err), multipart.EDECODE)
            assert.is_true(errlib.unwrap(err) == cause)
            assert.equal(calls, 2)
        end
        local form, err = multipart.decode(prefix, 'b')
        assert.is_nil(form)
        assert.equal(errlib.typeof(err), multipart.EDECODE)
        assert.not_nil(errlib.is(err, errno.EINVAL))
    end
end

function testcase.decode_accepts_a_folded_file_disposition()
    local input = input_for('Content-Disposition: form-data;\r\n name="foo";\r\n' ..
        ' filename="a.txt"', 'file payload')
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', './folded_upload', nil, 1)
        assert.is_nil(err)
        local part = form.foo[1]
        uploads[#uploads + 1] = part
        assert.equal(part.filename, 'a.txt')
        assert.equal(part.params, { name = 'foo', filename = 'a.txt' })
        assert.equal(part.file:read('*a'), 'file payload')
    end
end

function testcase.decode_preserves_whitespace_surrounding_a_fold_in_a_quoted_value()
    local input = input_for('Content-Disposition: form-data; name="foo"; custom="a \t\r\n b"')
    for _, source in ipairs({ input, reader(input) }) do
        local form, err = multipart.decode(source, 'b', nil, nil, 1)
        assert.is_nil(err)
        assert.equal(form.foo[1].params.custom, 'a \t b')
    end
end

function testcase.decode_preserves_trailing_field_and_continuation_whitespace()
    local disposition = 'form-data; name="foo"'
    for _, suffix in ipairs({ ' \t', '\r\n \t' }) do
        local input = input_for('Content-Disposition: ' .. disposition .. suffix)
        local form, err = multipart.decode(input, 'b')
        assert.is_nil(err)
        assert.equal(form.foo[1].header['content-disposition'], { disposition .. ' \t' })
        for split = 1, #input - 1 do
            form, err = multipart.decode(reader(input, split), 'b')
            assert.is_nil(err)
            assert.equal(form.foo[1].params, { name = 'foo' })
            assert.equal(form.foo[1].header['content-disposition'], { disposition .. ' \t' })
        end
    end
end
