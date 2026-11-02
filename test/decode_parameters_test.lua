local testcase = require('testcase')
local assert = require('assert')
local multipart = require('form.multipart')
local files = {}

function testcase.after_each()
    for _, part in ipairs(files) do
        if io.type(part.file) == 'file' then part.file:close() end
        if part.pathname then os.remove(part.pathname) end
    end
    files = {}
end

local function decode(disposition, chunksize)
    local input = '--b\r\nContent-Disposition: ' .. disposition ..
        '\r\n\r\npayload\r\n--b--'
    if not chunksize then return multipart.decode(input, 'b') end
    local pos = 1
    return multipart.decode({
        read = function(_, n)
            if pos > #input then return nil end
            local chunk = input:sub(pos, pos + n - 1)
            pos = pos + #chunk
            return chunk
        end,
    }, 'b', nil, nil, chunksize)
end

function testcase.decode_preserves_parameter_values()
    local cases = {
        { 'form-data; name=foo; custom=bar', { name = 'foo', custom = 'bar' } },
        { 'form-data; name="a=b"; custom="a;b"; extra="a,b"',
          { name = 'a=b', custom = 'a;b', extra = 'a,b' } },
        { 'form-data; name="foo"; custom="a\\\"b\\\\c"; blank=""',
          { name = 'foo', custom = 'a"b\\c', blank = '' } },
        { 'form-data \t; NAME \t= "foo" \t; Custom = token \t',
          { name = 'foo', custom = 'token' } },
        { "form-data; name=foo; custom=!#$%&'*+-.^_`{|}~09Az",
          { name = 'foo', custom = "!#$%&'*+-.^_`{|}~09Az" } },
        { 'form-data; name=""', { name = '' } },
        { 'form-data; name=foo; custom="a\tb"; utf8="資料"',
          { name = 'foo', custom = 'a\tb', utf8 = '資料' } },
        { "form-data; name=foo; filename*=UTF-8''example.txt",
          { name = 'foo', ['filename*'] = "UTF-8''example.txt" } },
    }
    for _, case in ipairs(cases) do
        for _, chunksize in ipairs({ false, 1, 2, 7, 4096 }) do
            local form, err = decode(case[1], chunksize)
            assert.is_nil(err)
            local part = form[case[2].name][1]
            assert.equal(part.params, case[2])
            assert.equal(part.data, 'payload')
            local raw = part.header['content-disposition'][1]:gsub('[ \t]+$', '')
            local expected = case[1]:gsub('[ \t]+$', '')
            assert.equal(raw, expected)
        end
    end
end

function testcase.decode_preserves_quoted_control_bytes()
    -- RFC 822 sections 3.3 and 3.4.9 allow these bytes in qtext.
    -- LF is a header line boundary; unescaped CR is not qtext.
    local bytes = {}
    for byte = 0, 127 do
        if (byte < 32 or byte == 127) and byte ~= 10 and byte ~= 13 then
            bytes[#bytes + 1] = string.char(byte)
        end
    end
    local value = table.concat(bytes)
    for _, chunksize in ipairs({ false, 1, 2, 7, 4096 }) do
        local form, err = decode('form-data; name=foo; custom="' .. value .. '"', chunksize)
        assert.is_nil(err)
        assert.equal(form.foo[1].params.custom, value)
    end
end

function testcase.decode_preserves_quoted_pair_bytes()
    -- RFC 822 section 3.3: quoted-pair = backslash CHAR, including CR.
    for _, value in ipairs({ '\0', '\8', '\r', '\127', ';', '=', '"', '\\' }) do
        for _, chunksize in ipairs({ false, 1, 2, 7, 4096 }) do
            local form, err = decode('form-data; name=foo; custom="\\' .. value .. '"', chunksize)
            assert.is_nil(err)
            assert.equal(form.foo[1].params.custom, value)
        end
    end
end

function testcase.decode_preserves_quoted_and_empty_filenames()
    for _, filename in ipairs({ '', 'a=b;c.txt' }) do
        local disposition = 'form-data; name="foo"; filename="' .. filename .. '"'
        for _, chunksize in ipairs({ false, 1, 7 }) do
            local form, err = decode(disposition, chunksize)
            assert.is_nil(err)
            local part = form.foo[1]
            files[#files + 1] = part
            assert.equal(part.filename, filename)
            assert.equal(part.params, { name = 'foo', filename = filename })
            assert.equal(part.file:read('*a'), 'payload')
        end
    end
end

function testcase.decode_rejects_invalid_or_ambiguous_parameters()
    for _, disposition in ipairs({
        'form-data; name="foo',
        'form-data; name=foo extra=bar',
        'form-data; name=foo; custom=',
        'form-data; name=foo; custom="ok"junk',
        'form-data; name=foo; custom="trailing\\',
        'form-data; name=foo; name=bar',
        'form-data; name=foo; NAME=foo',
        'form-data; name=foo; =bad',
        'form-data; name=foo; custom=hello/world',
        'form-data; name=foo; custom=資料',
        'form-data; name=foo; custom="a\rb"',
        'form-data; name=foo; custom=a\0b',
    }) do
        local form, err = decode(disposition)
        assert.is_nil(form)
        assert.match(tostring(err), 'invalid Content-Disposition')
    end
end

function testcase.decode_rejects_missing_name_without_parameter_separator()
    for _, chunksize in ipairs({ false, 1, 7 }) do
        local form, err = decode('form-data', chunksize)
        assert.is_nil(form)
        assert.match(tostring(err), 'does not contain a name parameter')
    end
end
