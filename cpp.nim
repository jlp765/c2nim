#
#
#      c2nim - C to Nim source converter
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# Preprocessor support

const
  c2nimSymbol = "C2NIM"

proc eatNewLine(p: var Parser, n: PNode) =
  if p.tok.xkind == pxLineComment:
    skipCom(p, n)
    if p.tok.xkind == pxNewLine: getTok(p)
  elif p.tok.xkind == pxNewLine:
    eat(p, pxNewLine)

proc skipLine(p: var Parser) =
  while p.tok.xkind notin {pxEof, pxNewLine, pxLineComment}: getTok(p)
  eatNewLine(p, nil)

proc parseDefineBody(p: var Parser, tmplDef: PNode): string =
  if p.tok.xkind == pxCurlyLe or
    (p.tok.xkind == pxSymbol and (
        declKeyword(p, p.tok.s) or stmtKeyword(p.tok.s))):
    addSon(tmplDef, statement(p))
    result = "stmt"
  elif p.tok.xkind in {pxLineComment, pxNewLine}:
    addSon(tmplDef, buildStmtList(newNodeP(nkNilLit, p)))
    result = "stmt"
  else:
    addSon(tmplDef, buildStmtList(expression(p)))
    result = "expr"

proc parseDefine(p: var Parser; hasParams: bool): PNode =
  if hasParams:
    # a macro with parameters:
    result = newNodeP(nkTemplateDef, p)
    addSon(result, skipIdentExport(p, skTemplate))
    addSon(result, ast.emptyNode)
    eat(p, pxParLe)
    var params = newNodeP(nkFormalParams, p)
    # return type; not known yet:
    addSon(params, ast.emptyNode)
    if p.tok.xkind != pxParRi:
      var identDefs = newNodeP(nkIdentDefs, p)
      while p.tok.xkind != pxParRi:
        addSon(identDefs, skipIdent(p, skParam))
        skipStarCom(p, nil)
        if p.tok.xkind != pxComma: break
        getTok(p)
      addSon(identDefs, newIdentNodeP("expr", p))
      addSon(identDefs, ast.emptyNode)
      addSon(params, identDefs)
    eat(p, pxParRi)

    addSon(result, ast.emptyNode) # no generic parameters
    addSon(result, params)
    addSon(result, ast.emptyNode) # no pragmas
    addSon(result, ast.emptyNode)
    var kind = parseDefineBody(p, result)
    params.sons[0] = newIdentNodeP(kind, p)
    eatNewLine(p, result)
  else:
    # a macro without parameters:
    result = newNodeP(nkConstSection, p)
    while true:
      var c = newNodeP(nkConstDef, p)
      var mTokStr = p.tok.s  # name of macro for reservedMacros
      addSon(c, skipIdentExport(p, skConst))
      addSon(c, ast.emptyNode)
      skipStarCom(p, c)
      if p.tok.xkind in {pxLineComment, pxNewLine, pxEof}:
        addSon(c, newIdentNodeP("true", p))
        p.options.reservedMacros.add(mTokStr, nil)  # empty (reserved) Macro
      else:
        if p.tok.s.startsWith("__"):
          p.options.reservedMacros.add(mTokStr, p.tok.s)  # reserved Macro
        addSon(c, expression(p))
      addSon(result, c)
      eatNewLine(p, c)
      if p.tok.xkind == pxDirective and p.tok.s == "define":
        getTok(p)
      else:
        break
  assert result != nil

proc parseDefBody(p: var Parser, m: var Macro, params: seq[string]) =
  m.body = @[]
  # A little hack: We safe the context, so that every following token will be
  # put into a newly allocated TToken object. Thus we can just save a
  # reference to the token in the macro's body.
  saveContext(p)
  while p.tok.xkind notin {pxEof, pxNewLine, pxLineComment}:
    case p.tok.xkind
    of pxSymbol, pxDirective, pxDirectiveParLe:
      let toString = p.tok.xkind != pxSymbol
      # is it a parameter reference? (or possibly #param with a toString)
      var tok = p.tok
      for i in 0..high(params):
        if params[i] == p.tok.s:
          new(tok)
          tok.xkind = if toString: pxMacroParamToStr else: pxMacroParam
          tok.iNumber = i
          break
      m.body.add(tok)
    else:
      m.body.add(p.tok)
    # we do not want macro expansion here:
    rawGetTok(p)
  eatNewLine(p, nil)
  closeContext(p)
  # newline token might be overwritten, but this is not
  # part of the macro body, so it is safe.

proc parseDef(p: var Parser, m: var Macro; hasParams: bool) =
  m.name = p.tok.s
  rawGetTok(p)
  var params: seq[string] = @[]
  # parse parameters:
  if hasParams:
    eat(p, pxParLe)
    while p.tok.xkind != pxParRi:
      expectIdent(p)
      params.add(p.tok.s)
      getTok(p)
      skipStarCom(p, nil)
      if p.tok.xkind != pxComma: break
      getTok(p)
    eat(p, pxParRi)
  m.params = if hasParams: params.len else: -1
  parseDefBody(p, m, params)

proc isDir(p: Parser, dir: string): bool =
  result = p.tok.xkind in {pxDirectiveParLe, pxDirective} and p.tok.s == dir

proc parseInclude(p: var Parser): PNode =
  result = newNodeP(nkImportStmt, p)
  while isDir(p, "include"):
    getTok(p) # skip "include"
    if p.tok.xkind == pxStrLit and pfSkipInclude notin p.options.flags:
      let file = mangledIdent(changeFileExt(p.tok.s, ""), p, skVar)
      #newStrNodeP(nkStrLit, changeFileExt(p.tok.s, ""), p)
      addSon(result, file)
      getTok(p)
      skipStarCom(p, file)
      eatNewLine(p, nil)
    else:
      skipLine(p)
  if sonsLen(result) == 0:
    # we only parsed includes that we chose to ignore:
    result = ast.emptyNode

proc definedExprAux(p: var Parser): PNode =
  result = newNodeP(nkCall, p)
  addSon(result, newIdentNodeP("defined", p))
  addSon(result, skipIdent(p, skDontMangle))

proc parseStmtList(p: var Parser; sectionParser: SectionParser): PNode =
  result = newNodeP(nkStmtList, p)
  while true:
    case p.tok.xkind
    of pxEof: break
    of pxDirectiveParLe, pxDirective:
      case p.tok.s
      of "else", "endif", "elif": break
      else: discard
    else: discard
    addSon(result, sectionParser(p))

proc eatEndif(p: var Parser) =
  if isDir(p, "endif"):
    skipLine(p)
  else:
    parMessage(p, errXExpected, "#endif")

proc parseIfDirAux(p: var Parser, result: PNode; sectionParser: SectionParser) =
  addSon(result.sons[0], parseStmtList(p, sectionParser))
  while isDir(p, "elif"):
    var b = newNodeP(nkElifBranch, p)
    getTok(p)
    addSon(b, expression(p))
    eatNewLine(p, nil)
    addSon(b, parseStmtList(p, sectionParser))
    addSon(result, b)
  if isDir(p, "else"):
    var s = newNodeP(nkElse, p)
    skipLine(p)
    addSon(s, parseStmtList(p, sectionParser))
    addSon(result, s)
  eatEndif(p)

proc skipUntilEndif(p: var Parser) =
  var nested = 1
  while p.tok.xkind != pxEof:
    if isDir(p, "ifdef") or isDir(p, "ifndef") or isDir(p, "if"):
      inc(nested)
    elif isDir(p, "endif"):
      dec(nested)
      if nested <= 0:
        skipLine(p)
        return
    getTok(p)
  parMessage(p, errXExpected, "#endif")

type
  TEndifMarker = enum
    emElif, emElse, emEndif

proc skipUntilElifElseEndif(p: var Parser): TEndifMarker =
  var nested = 1
  while p.tok.xkind != pxEof:
    if isDir(p, "ifdef") or isDir(p, "ifndef") or isDir(p, "if"):
      inc(nested)
    elif isDir(p, "elif") and nested <= 1:
      return emElif
    elif isDir(p, "else") and nested <= 1:
      return emElse
    elif isDir(p, "endif"):
      dec(nested)
      if nested <= 0:
        return emEndif
    getTok(p)
  parMessage(p, errXExpected, "#endif")

proc parseIfdef(p: var Parser; sectionParser: SectionParser): PNode =
  getTok(p) # skip #ifdef
  expectIdent(p)
  case p.tok.s
  of "__cplusplus":
    skipUntilEndif(p)
    result = ast.emptyNode
  of c2nimSymbol:
    skipLine(p)
    result = parseStmtList(p, sectionParser)
    skipUntilEndif(p)
  else:
    result = newNodeP(nkWhenStmt, p)
    addSon(result, newNodeP(nkElifBranch, p))
    addSon(result.sons[0], definedExprAux(p))
    eatNewLine(p, nil)
    parseIfDirAux(p, result, sectionParser)

proc isIncludeGuard(p: var Parser): bool =
  var guard = p.tok.s
  skipLine(p)
  if p.tok.xkind == pxDirective and p.tok.s == "define":
    getTok(p) # skip #define
    expectIdent(p)
    result = p.tok.s == guard
    skipLine(p)

proc parseIfndef(p: var Parser; sectionParser: SectionParser): PNode =
  result = ast.emptyNode
  getTok(p) # skip #ifndef
  expectIdent(p)
  if p.tok.s == c2nimSymbol:
    skipLine(p)
    case skipUntilElifElseEndif(p)
    of emElif:
      result = newNodeP(nkWhenStmt, p)
      addSon(result, newNodeP(nkElifBranch, p))
      getTok(p)
      addSon(result.sons[0], expression(p))
      eatNewLine(p, nil)
      parseIfDirAux(p, result, sectionParser)
    of emElse:
      skipLine(p)
      result = parseStmtList(p, sectionParser)
      eatEndif(p)
    of emEndif: skipLine(p)
  else:
    # test if include guard:
    saveContext(p)
    if isIncludeGuard(p):
      closeContext(p)
      result = parseStmtList(p, sectionParser)
      eatEndif(p)
    else:
      backtrackContext(p)
      result = newNodeP(nkWhenStmt, p)
      addSon(result, newNodeP(nkElifBranch, p))
      var e = newNodeP(nkPrefix, p)
      addSon(e, newIdentNodeP("not", p))
      addSon(e, definedExprAux(p))
      eatNewLine(p, nil)
      addSon(result.sons[0], e)
      parseIfDirAux(p, result, sectionParser)

proc parseIfDir(p: var Parser; sectionParser: SectionParser): PNode =
  result = newNodeP(nkWhenStmt, p)
  addSon(result, newNodeP(nkElifBranch, p))
  getTok(p)
  addSon(result.sons[0], expression(p))
  eatNewLine(p, nil)
  parseIfDirAux(p, result, sectionParser)
  if pfAssumeIfIsTrue in p.options.flags:
    result = result.sons[0].sons[1]

proc parsePegLit(p: var Parser): Peg =
  var col = getColumn(p.lex) + 2
  getTok(p)
  if p.tok.xkind != pxStrLit: expectIdent(p)
  try:
    result = parsePeg(
      pattern = if p.tok.xkind == pxStrLit: p.tok.s else: escapePeg(p.tok.s),
      filename = p.lex.fileIdx.toFilename,
      line = p.lex.linenumber,
      col = col)
    getTok(p)
  except EInvalidPeg:
    parMessage(p, errUser, getCurrentExceptionMsg())

proc parseMangleDir(p: var Parser) =
  var pattern = parsePegLit(p)
  if p.tok.xkind != pxStrLit: expectIdent(p)
  p.options.mangleRules.add((pattern, p.tok.s))
  getTok(p)
  eatNewLine(p, nil)

proc modulePragmas(p: var Parser): PNode =
  if p.options.dynlibSym.len > 0 and not p.hasDeadCodeElimPragma:
    p.hasDeadCodeElimPragma = true
    result = newNodeP(nkPragma, p)
    var e = newNodeP(nkExprColonExpr, p)
    addSon(e, newIdentNodeP("deadCodeElim", p), newIdentNodeP("on", p))
    addSon(result, e)
  else:
    result = ast.emptyNode

proc parseOverride(p: var Parser; tab: StringTableRef) =
  getTok(p)
  expectIdent(p)
  tab[p.tok.s] = "true"
  getTok(p)
  eatNewLine(p, nil)

proc parseDir(p: var Parser; sectionParser: SectionParser): PNode =
  result = ast.emptyNode
  assert(p.tok.xkind in {pxDirective, pxDirectiveParLe})
  case p.tok.s
  of "define":
    let hasParams = p.tok.xkind == pxDirectiveParLe
    getTok(p)
    expectIdent(p)
    if p.options.toPreprocess.hasKey(p.tok.s):
      let L = p.options.macros.len
      setLen(p.options.macros, L+1)
      parseDef(p, p.options.macros[L], hasParams)
    else:
      result = parseDefine(p, hasParams)
  of "include": result = parseInclude(p)
  of "ifdef": result = parseIfdef(p, sectionParser)
  of "ifndef": result = parseIfndef(p, sectionParser)
  of "if": result = parseIfDir(p, sectionParser)
  of "cdecl", "stdcall", "ref", "skipinclude", "typeprefixes", "skipcomments",
     "keepbodies", "cpp", "nep1", "assumeifistrue", "structstruct":
    discard setOption(p.options, p.tok.s)
    getTok(p)
    eatNewLine(p, nil)
  of "header":
    var key = p.tok.s
    getTok(p)
    if p.tok.xkind == pxNewLine:
      discard setOption(p.options, key)
    else:
      if p.tok.xkind == pxStrLit:
        # try to be backwards compatible with older versions of c2nim:
        discard setOption(p.options, key, strutils.escape(p.tok.s))
      else:
        expectIdent(p)
        discard setOption(p.options, key, p.tok.s)
      getTok(p)
    eatNewLine(p, nil)
    result = modulePragmas(p)
  of "dynlib", "prefix", "suffix", "class", "discardableprefix":
    var key = p.tok.s
    getTok(p)
    if p.tok.xkind != pxStrLit: expectIdent(p)
    discard setOption(p.options, key, p.tok.s)
    getTok(p)
    eatNewLine(p, nil)
    result = modulePragmas(p)
  of "mangle":
    parseMangleDir(p)
  of "pp":
    parseOverride(p, p.options.toPreprocess)
  of "inheritable", "pure":
    parseOverride(p, p.options.inheritable)
  of "def":
    let hasParams = p.tok.xkind == pxDirectiveParLe
    rawGetTok(p)
    expectIdent(p)
    let L = p.options.macros.len
    setLen(p.options.macros, L+1)
    parseDef(p, p.options.macros[L], hasParams)
  of "private":
    var pattern = parsePegLit(p)
    p.options.privateRules.add(pattern)
    eatNewLine(p, nil)
  else:
    # ignore unimportant/unknown directive ("undef", "pragma", "error")
    skipLine(p)

