import httpclient
import cgi
import pegs
import sets
import os
import osproc

type CompilationLevel* = enum
    SIMPLE_OPTIMIZATIONS
    WHITESPACE_ONLY
    ADVANCED_OPTIMIZATIONS

proc urlencode(params: openarray[tuple[k : string, v: string]]): string =
    result = ""
    for i, p in params:
        if i != 0:
            result &= "&"
        result &= encodeUrl(p.k)
        result &= "="
        result &= encodeUrl(p.v)

proc closureCompilerExe(): string =
    result = findExe("closure-compiler")
    # TODO: Add more variants here

var bannedNames = ["new", "delete"].toSet()

# Javascript generated by Nim has some incompatibilities with closure compiler
# advanced optimizations:
# - Filed* properties are accessed by indexing and by dot-syntax. E.g:
#       myObj["Field1"]
#       myObj.Field1
#   Closure compiler does not expect non-uniform property access, so we need
#   to extern Field* properties, so that it doesn't rename them.
proc externsFromNimSourceCode(code: string): string =
    result = ""
    let p = peg"""\.{\ident}"""
    var matches = code.findAll(p)#.toSet()
    for m in matches.mitems:
        var s : array[1, string]
        discard m.match(p, s)
        m = s[0]

    for i in matches.toSet():
        if i notin bannedNames:
            result &= "Object.prototype." & i & ";\n"

proc optimizationLevelOptionForCLI(lvl: CompilationLevel): string = $lvl

proc compileSource*(sourceCode: string, level: CompilationLevel = SIMPLE_OPTIMIZATIONS): string =
    let compExe = closureCompilerExe()
    let externs = externsFromNimSourceCode(sourceCode)
    if compExe.len > 0:
        # Run compiler locally
        let sourcePath = getTempDir() / "closure_js_tmp.js"
        let externPath = getTempDir() / "closure_js_extern_tmp.js"
        let outputPath = getTempDir() / "closure_js_compiled_tmp.js"
        writeFile(sourcePath, sourceCode)
        writeFile(externPath, externs)
        discard execProcess(compExe,
            [sourcePath, "--compilation_level", optimizationLevelOptionForCLI(level),
            "--externs", externPath, "--js_output_file", outputPath], options = {poStdErrToStdOut})
        removeFile(sourcePath)
        removeFile(externPath)
        result = readFile(outputPath)
        removeFile(outputPath)
    else:
        # Use web API
        var data = urlencode({
            "compilation_level" : $level,
            "output_format" : "text",
            "output_info" : "compiled_code",
            "js_code" : sourceCode,
            "js_externs" : externs
            })
        result = postContent("http://closure-compiler.appspot.com/compile", body=data,
            extraHeaders="Content-type: application/x-www-form-urlencoded")

proc compileFile*(f: string, level: CompilationLevel = SIMPLE_OPTIMIZATIONS): string = compileSource(readFile(f), level)
proc compileFileAndRewrite*(f: string, level: CompilationLevel = SIMPLE_OPTIMIZATIONS): bool {.discardable.} =
    result = true
    let r = compileSource(readFile(f), level)
    writeFile(f, r)

when isMainModule:
    import parseopt2

    proc usage() =
        echo "closure_compiler [-q] [-a|-w] file1 [fileN...]"

    proc main() =
        var files = newSeq[string]()
        var level = SIMPLE_OPTIMIZATIONS
        var quiet = false
        for kind, key, val in getopt():
            case kind:
                of cmdArgument: files.add(key)
                of cmdShortOption:
                    case key:
                        of "a": level = ADVANCED_OPTIMIZATIONS
                        of "w": level = WHITESPACE_ONLY
                        of "q": quiet = true
                        else:
                            usage()
                            return
                else:
                    usage()
                    return

        if files.len == 0:
            usage()
            return

        for f in files:
            if not quiet:
                echo "Processing: ", f
            compileFileAndRewrite(f, level)

    main()
