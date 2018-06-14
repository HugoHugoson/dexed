unit ce_gdbmi2json;

{$I ce_defines.inc}

interface

uses
  Classes, SysUtils, fpjson, fgl;

type

  TTokenKind = (
    tkInvalid,  // on error, easier to leave parsing
    tkNl,       // #13#10 or #10, i.e te "nl" rule
    tkToken,    // unquoted text
    tkAnd,      // &
    tkAt,       // @
    tkTiddle,   // ~
    tkComma,    // ,
    tkHat,      // ^
    tkStar,     // *
    tkLeftSquare, // [
    tkRightSquare,// ]
    tkLeftCurly,  // {
    tkRightCurly, // }
    tkString, // quoted string (also used for "c-string" but no checked for now)
    tkAss,    // =
    tkPlus,   // +
    tkGdb,    // (gdb)
    tkEOF     // additional guard for safe lookups
  );

  PToken = ^TToken;
  TToken = record
  private
    data: pchar;
    length: longInt;
    kind: TTokenKind;
  public
    function text: string;
  end;

  TTokenList = class(specialize TFPGList<PToken>)
    procedure popFront();
    procedure clearAndDispose;
    destructor destroy; override;
  end;

  TGdbMiNodeKind = (
    gnkLogStreamOutput,
    gnkTargetStreamOutput,
    gnkConsoleStreamOutput,
    gnkExecAsyncOutput,
    gnkStatusAsyncOutput,
    gnkNotifyAsyncOutput
  );

(**
 * Tokenizes and parses some GDB-MI output, according to the BNF grammar
 * (https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI-Output-Syntax.html)
 * and finally returns a JSON structure that follows grammar rules and names.
 *)
function gdbmi2json(const str: string): TJSONObject;

implementation

{$IFDEF DEBUG}
var
  r: TJSONObject;
  t: TTokenList;
{$ENDIF}

procedure TTokenList.popFront();
begin
  //dispose(Items[0]);
  Delete(0);
end;

procedure TTokenList.clearAndDispose;
begin
  while count <> 0 do
    popFront();
end;

destructor TTokenList.destroy;
begin
  inherited;
  clearAndDispose;
end;

//TODO-cGDB: handle escapes in TToken.text()
function TToken.text: string;
begin
  result := data[0 .. length];
end;

procedure lex(const str: string; list: TTokenList);
var
  i: integer;
  s: integer;

  procedure addToken(k: TTokenKind);
  var
    t: PToken;
  begin
    t := new(PToken);
    t^.length:= i-s-1;
    if (k <> tkEOF) and (k <> tkInvalid) then
      t^.data:= @str[s]
    else
      t^.data:= nil;
    if k = tkString then
    begin
      t^.data += 1;
      t^.length -= 2;
    end;
    t^.kind:= k;
    list.Add(t);
    s := i;
  end;

begin
  s := 1;
  i := 1;
  while i <= str.length do
  begin
    case str[i] of

      '&':
      begin
        i += 1;
        addToken(TTokenKind.tkAnd);
      end;

      '@':
      begin
        i += 1;
        addToken(TTokenKind.tkAt);
      end;

      '+':
      begin
        i += 1;
        addToken(TTokenKind.tkPlus);
      end;

      '~':
      begin
        i += 1;
        addToken(TTokenKind.tkTiddle);
      end;

      '^':
      begin
        i += 1;
        addToken(TTokenKind.tkHat);
      end;

      '=':
      begin
        i += 1;
        addToken(TTokenKind.tkAss);
      end;

      ',':
      begin
        i += 1;
        addToken(TTokenKind.tkComma);
      end;

      '*':
      begin
        i += 1;
        addToken(TTokenKind.tkStar);
      end;

      '{':
      begin
        i += 1;
        addToken(TTokenKind.tkLeftCurly);
      end;

      '}':
      begin
        i += 1;
        addToken(TTokenKind.tkRightCurly);
      end;

      '[':
      begin
        i += 1;
        addToken(TTokenKind.tkLeftSquare);
      end;

      ']':
      begin
        i += 1;
        addToken(TTokenKind.tkRightSquare);
      end;

      #10:
      begin
        i += 1;
        addToken(TTokenKind.tkNl);
      end;

      #13:
      begin
        i += 1;
        if str[i] = #10 then
        begin
          i += 1;
          addToken(TTokenKind.tkNl);
        end
        else
        begin
          addToken(TTokenKind.tkInvalid);
        end;
      end;

      '(':
      begin
        if (i + 4 <= str.length) and (str[i .. i + 4] = '(gdb)') then
        begin
          i += 5;
          addToken(TTokenKind.tkGdb);
        end
        else
        begin
          addToken(TTokenKind.tkInvalid);
        end;
      end;

      '"':
      begin
        while true do
        begin
          i += 1;
          if i > str.length then
          begin
            addToken(TTokenKind.tkInvalid);
            break;
          end;
          if str[i] = '\' then
          begin
            i += 1;
            if str[i] = '"' then
              i+= 1;
          end;
          if str[i] = '"' then
          begin
            i += 1;
            addToken(TTokenKind.tkString);
            break;
          end;
        end;
      end

      else
      begin
        while true do
        begin
          i += 1;
          if i > str.length then
          begin
            addToken(TTokenKind.tkInvalid);
            break;
          end;
          if str[i] in ['&', '~', '@', '=', '{', '}','[', ']', '*', '"', ',' ,
            #10, #13] then
          begin
            addToken(TTokenKind.tkToken);
            break;
          end;
        end;
      end;

    end;
  end;

  addToken(TTokenKind.tkEOF);

end;

(**
 * BNF: log-stream-output → "&" c-string nl
 *)
function parseLogStreamOutput(tokens: TTokenList): TJSONObject;
var
  s: string;
begin
  if tokens[0]^.kind <> TTokenKind.tkAnd then
    exit(nil);
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkString then
    exit(nil);
  s := tokens[0]^.text();
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkNl then
    exit(nil);
  tokens.popFront();
  result := TJSONObject.Create;
  result['kind'] := TJSONIntegerNumber.Create(integer(gnkLogStreamOutput));
  result['output'] := TJSONString.Create(s);
end;

(**
 * BNF: target-stream-output → "@" c-string nl
 *)
function parseTargetStreamOutput(tokens: TTokenList): TJSONObject;
var
  s: string;
begin
  if tokens[0]^.kind <> TTokenKind.tkAt then
    exit(nil);
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkString then
    exit(nil);
  s := tokens[0]^.text();
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkNl then
    exit(nil);
  tokens.popFront();
  result := TJSONObject.Create;
  result['kind'] := TJSONIntegerNumber.Create(integer(gnkTargetStreamOutput));
  result['output'] := TJSONString.Create(s);
end;

(**
 * BNF: console-stream-output → "~" c-string nl
 *)
function parseConsoleStreamOutput(tokens: TTokenList): TJSONObject;
var
  s: string;
begin
  if tokens[0]^.kind <> TTokenKind.tkTiddle then
    exit(nil);
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkString then
    exit(nil);
  s := tokens[0]^.text();
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkNl then
    exit(nil);
  tokens.popFront();
  result := TJSONObject.Create;
  result['kind'] := TJSONIntegerNumber.Create(integer(gnkConsoleStreamOutput));
  result['output'] := TJSONString.Create(s);
end;

function parseListValue(tokens: TTokenList): TJSONArray; forward;
function parseTupleValue(tokens: TTokenList): TJSONObject; forward;
function parseResult(tokens: TTokenList; obj: TJSONObject): boolean; forward;

(**
 * BNF: value → const | tuple | list
 *)
function parseValue(tokens: TTokenList): TJSONData;
begin
  result := nil;
  case tokens[0]^.kind of
    tkString:
    begin
      result := TJSONString.Create(tokens[0]^.text());
      tokens.popFront();
    end;
    tkLeftCurly:
    begin
      result := parseTupleValue(tokens);
    end;
    tkLeftSquare:
    begin
      result := parseListValue(tokens);
    end;
    else assert(false);
  end;
end;

(**
 * BNF: list → "[]" | "[" value ( "," value )* "]" | "[" result ( "," result )* "]"
 *)
function parseListValue(tokens: TTokenList): TJsonArray;
var
  r: TJSONData;
begin
  result := nil;
  if tokens[0]^.kind <> TTokenKind.tkLeftSquare then
    exit(nil);
  tokens.popFront();
  result := TJsonArray.Create();
  if tokens[0]^.kind = TTokenKind.tkRightSquare then
  begin
    tokens.popFront();
    exit;
  end;
  r := parseValue(tokens);
  if r = nil then
  begin
    freeAndNil(result);
    exit;
  end;
  result.Items[0] := r;
  while tokens[0]^.kind = tkComma do
  begin
    tokens.popFront();
    r := parseValue(tokens);
    if r = nil then
    begin
      freeAndNil(result);
      exit;
    end;
    result.Items[result.Count] := r;
  end;
  if tokens[0]^.kind <> tkRightSquare then
  begin
    freeAndNil(result);
    exit;
  end;
  tokens.popFront();
end;

(**
 * BNF: tuple → "{}" | "{" result ( "," result )* "}"
 *)
function parseTupleValue(tokens: TTokenList): TJSONObject;
begin
  result := nil;
  if tokens[0]^.kind <> TTokenKind.tkLeftCurly then
    exit(nil);
  tokens.popFront();
  result := TJSONObject.Create();
  if tokens[0]^.kind = TTokenKind.tkRightCurly then
  begin
    tokens.popFront();
    exit;
  end;
  if not parseResult(tokens, result) then
  begin
    freeAndNil(result);
    exit;
  end;
  while tokens[0]^.kind = tkComma do
  begin
    tokens.popFront();
    if not parseResult(tokens, result) then
    begin
      freeAndNil(result);
      exit;
    end;
  end;
  if tokens[0]^.kind <> tkRightCurly then
  begin
    freeAndNil(result);
    exit;
  end;
  tokens.popFront();
end;

(**
 * BNF: result → variable "=" value
 *)
function parseResult(tokens: TTokenList; obj: TJSONObject): boolean;
var
  v: TJSONData;
  s: ansistring;
begin
  result := false;
  if tokens[0]^.kind <> TTokenKind.tkToken then
    exit;
  s := tokens[0]^.text();
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkAss then
    exit;
  tokens.popFront();
  v := parseValue(tokens);
  if v = nil then
    exit;

  obj[s] := v;
  result := true;
end;

(**
 * BNF: result-record → [ token ] "^" result-class ( "," result )* nl
 *)
function parseResultRecord(tokens: TTokenList): TJSONObject;
var
  r: TJSONObject;
begin
  result := TJSONObject.Create;
  if tokens[0]^.kind = TTokenKind.tkToken then
  begin
    result['token'] := TJSONString.Create(tokens[0]^.text());
    tokens.popFront();
  end;
  if tokens[0]^.kind <> TTokenKind.tkHat then
  begin
    freeAndNil(result);
    exit;
  end;
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkToken then
  begin
    freeAndNil(result);
    exit;
  end;
  result['result-class'] := TJSONString.Create(tokens[0]^.text());
  tokens.popFront();
  r := TJSONObject.Create();
  result['results'] := r;

  while tokens[0]^.kind = TTokenKind.tkComma do
  begin
    tokens.popFront();
    if not parseResult(tokens, r) then
    begin
      freeAndNil(result);
      exit;
    end;
  end;
end;

(**
 * BNF: async-record → [ token ] ("*" | "+" | "=") async-class ( "," result )* nl
 *)
function parseAsyncRecord(tokens: TTokenList): TJSONObject;
var
  r: TJSONObject;
begin
  result := TJSONObject.Create;
  if tokens[0]^.kind = TTokenKind.tkToken then
  begin
    result['token'] := TJSONString.Create(tokens[0]^.text());
    tokens.popFront();
  end;
  case tokens[0]^.kind of
    tkStar: result['type'] := TJSONIntegerNumber.Create(integer(gnkExecAsyncOutput));
    tkPlus: result['type'] := TJSONIntegerNumber.Create(integer(gnkStatusAsyncOutput));
    tkAss:  result['type'] := TJSONIntegerNumber.Create(integer(gnkNotifyAsyncOutput));
  end;
  tokens.popFront();
  if tokens[0]^.kind <> TTokenKind.tkToken then
  begin
    freeAndNil(result);
    exit;
  end;
  result['async-class'] := TJSONString.Create(tokens[0]^.text());
  tokens.popFront();

  r := TJSONObject.Create();
  while tokens[0]^.kind = TTokenKind.tkComma do
  begin
    tokens.popFront();
    if not parseResult(tokens, r) then
    begin
      freeAndNil(result);
      exit;
    end;
  end;
  if tokens[0]^.kind <> TTokenKind.tkNl then
  begin
    freeAndNil(result);
    exit;
  end;
  tokens.popFront();
  result['results'] := r;
end;

(**
 * BNF: stream-record → console-stream-output | target-stream-output | log-stream-output
 *)
function parseStreamRecord(tokens: TTokenList): TJSonObject;
begin
  result := nil;
  if not assigned (result) then
    result := parseConsoleStreamOutput(tokens);
  if not assigned (result) then
    result := parseTargetStreamOutput(tokens);
  if not assigned (result) then
    result := parseLogStreamOutput(tokens);
end;

function asyncRecordBegins(tokens: TTokenList): boolean;
begin
  result := ((tokens.Count > 0) and  (tokens[0]^.kind in [tkStar, tkAss, tkPlus])) or
    ((tokens.Count > 1) and (tokens[0]^.kind = tkToken)
    and (tokens[1]^.kind in [tkStar, tkAss, tkPlus]));
end;

function streamRecordBegins(tokens: TTokenList): boolean;
begin
  result := (tokens.Count > 0) and  (tokens[0]^.kind in [tkTiddle, tkAt, tkAnd]);
end;

(**
 * BNF: out-of-band-record → async-record | stream-record
 *)
function parseOutOfBandRecord(tokens: TTokenList): TJSonObject;
begin
  if streamRecordBegins(tokens) then
    result := parseStreamRecord(tokens)
  else
    result := parseAsyncRecord(tokens);
end;

function outOfBandRecordBegins(tokens: TTokenList): boolean;
begin
  result := asyncRecordBegins(tokens) or streamRecordBegins(tokens);
end;

(**
 * BNF: output → ( out-of-band-record )* [ result-record ] "(gdb)" nl
 *)
function parseOutput(tokens: TTokenList): TJSonObject;
var
  a: TJSONArray;
  o: TJSONObject;
begin
  result := TJSonObject.Create;
  if outOfBandRecordBegins(tokens) then
  begin
    a := TJSONArray.Create;
    result['out-of-band-records'] := a;
    while outOfBandRecordBegins(tokens) do
    begin
      o := parseOutOfBandRecord(tokens);
      if assigned(o) then
        a.Add(o);
    end;
  end;
  if tokens[0]^.kind <> tkGdb then
  begin
    result['result-record'] := parseResultRecord(tokens);
  end;
  if tokens[0]^.kind <> tkGdb then
  begin
    //result.Free;
    //result := nil;
  end;
  tokens.popFront();
  //assert(tokens.Count > 0);
  //if tokens[0]^.kind <> tkNl then
  begin
    //result.Free;
    //result := nil;
  end;
  //tokens.popFront();
  //assert(tokens.Count > 0);
  //if tokens[0]^.kind <> tkEOF then
  //begin
  //  result.Free;
  //  result := nil;
  //end;
end;

function gdbmi2json(const str: string): TJSONObject;
var
  tokens: TTokenList;
begin
  result := nil;
  tokens := TTokenList.Create;
  try
    lex(str, tokens);
    if tokens.Count < 2 then
      exit;
    result := parseOutput(tokens);
  finally
    tokens.Free;
  end;
end;


{$IFDEF DEBUG}
begin

  t := TTokenList.Create;
  lex('^done,asm_insns=[{address="0x000107c0",func-name="main"}](gdb)'#10,t);

  assert(t[0]^.text = '^');
  assert(t[1]^.text = 'done');
  assert(t[2]^.text = ',');
  assert(t[3]^.text = 'asm_insns');
  assert(t[4]^.text = '=');
  assert(t[5]^.text = '[');
  assert(t[6]^.text = '{');
  assert(t[7]^.text = 'address');
  assert(t[8]^.text = '=');
  assert(t[9]^.text = '0x000107c0');
  assert(t[10]^.text = ',');
  assert(t[11]^.text = 'func-name');
  assert(t[12]^.text = '=');
  assert(t[13]^.text = 'main');
  assert(t[14]^.text = '}');
  assert(t[15]^.text = ']');
  assert(t[16]^.text = '(gdb)');
  assert(t[17]^.text = #10);
  assert(t[18]^.kind = tkEOF);

  r := parseOutput(t);

  with TMemoryStream.Create do
  try
    WriteAnsiString(r.AsJSON);
    SaveToFile('result-record-array-of-objects.json');
  finally
    free;
  end;

  t.Free;
  r.Free;

  ///////////////////////////////////////////////

  t := TTokenList.Create;
  lex('~abc'#10'@efg'#10'&hij'#10'(gdb)'#10,t);

  assert(t[0]^.kind = tkTiddle);
  assert(t[1]^.text = 'abc');
  assert(t[2]^.kind = tkNl);
  assert(t[3]^.kind = tkAt);
  assert(t[4]^.text = 'efg');
  assert(t[5]^.kind = tkNl);
  assert(t[6]^.kind = tkAnd);
  assert(t[7]^.text = 'hij');
  assert(t[8]^.kind = tkNl);
  assert(t[9]^.kind = tkGdb);
  assert(t[10]^.kind = tkNl);
  assert(t[11]^.kind = tkEOF);

  r := parseOutput(t);

  with TMemoryStream.Create do
  try
    WriteAnsiString(r.AsJSON);
    SaveToFile('out-of-band-records.json');
  finally
    free;
  end;

  t.Free;
  r.Free;

{$ENDIF}
end.

