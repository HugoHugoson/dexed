unit ce_dcd;

{$I ce_defines.inc}

interface

uses
  Classes, SysUtils, process, forms, strutils, LazFileUtils,
  {$IFDEF WINDOWS}
  windows,
  {$ENDIF}
  ce_common, ce_writableComponent, ce_interfaces, ce_observer, ce_synmemo,
  ce_stringrange, ce_projutils;

type

  TIntOpenArray = array of integer;

  (**
   * Wrap the dcd-server and dcd-client processes.
   *
   * Projects folders are automatically imported: ICEProjectObserver.
   * Completion, hints and declaration finder automatically work on the current
   *   document: ICEDocumentObserver.
   *)
  TCEDcdWrapper = class(TWritableLfmTextComponent, ICEProjectObserver, ICEDocumentObserver)
  private
    fTempLines: TStringList;
    fInputSource: string;
    fImportCache: TStringHashSet;
    fPortNum: Word;
    fServerWasRunning: boolean;
    fClient, fServer: TProcess;
    fAvailable: boolean;
    fServerListening: boolean;
    fDoc: TCESynMemo;
    fProj: ICECommonProject;
    procedure killServer;
    procedure terminateClient; inline;
    procedure waitClient; inline;
    procedure updateServerlistening;
    procedure writeSourceToInput; {$IFNDEF DEBUG}inline;{$ENDIF}
    function checkDcdSocket: boolean;
    function getIfLaunched: boolean;
    //
    procedure projNew(project: ICECommonProject);
    procedure projChanged(project: ICECommonProject);
    procedure projClosing(project: ICECommonProject);
    procedure projFocused(project: ICECommonProject);
    procedure projCompiling(project: ICECommonProject);
    procedure projCompiled(project: ICECommonProject; success: boolean);
    //
    procedure docNew(document: TCESynMemo);
    procedure docFocused(document: TCESynMemo);
    procedure docChanged(document: TCESynMemo);
    procedure docClosing(document: TCESynMemo);
  published
    property port: word read fPortNum write fPortNum default 0;
  public
    constructor create(aOwner: TComponent); override;
    destructor destroy; override;
    //
    class procedure relaunch; static;
    class function noDcdPassedAsArg: boolean; static;
    //
    procedure addImportFolders(const folders: TStrings);
    procedure addImportFolder(const folder: string);
    procedure getComplAtCursor(list: TStringList);
    procedure getCallTip(out tips: string);
    procedure getDdocFromCursor(out comment: string);
    procedure getDeclFromCursor(out fname: string; out position: Integer);
    procedure getLocalSymbolUsageFromCursor(var locs: TIntOpenArray);
    //
    property available: boolean read fAvailable;
    property launchedByCe: boolean read getIfLaunched;
  end;

    function DCDWrapper: TCEDcdWrapper;

implementation

var
  fDcdWrapper: TCEDcdWrapper = nil;

const
  clientName = 'dcd-client' + exeExt;
  serverName = 'dcd-server' + exeExt;
  optsname = 'dcdoptions.txt';


{$REGION Standard Comp/Obj------------------------------------------------------}
constructor TCEDcdWrapper.create(aOwner: TComponent);
var
  fname: string;
  i: integer = 0;
begin
  inherited;
  //
  fname := getCoeditDocPath + optsname;
  if fname.fileExists then
    loadFromFile(fname);
  //
  fAvailable := exeInSysPath(clientName) and exeInSysPath(serverName)
    and not noDcdPassedAsArg();
  if not fAvailable then
    exit;
  //
  fClient := TProcess.Create(self);
  fClient.Executable := exeFullName(clientName);
  fClient.Options := [poUsePipes{$IFDEF WINDOWS}, poNewConsole{$ENDIF}];
  fClient.ShowWindow := swoHIDE;
  //
  fServerWasRunning := AppIsRunning((serverName));
  if not fServerWasRunning then
  begin
    fServer := TProcess.Create(self);
    fServer.Executable := exeFullName(serverName);
    fServer.Options := [{$IFDEF WINDOWS} poNewConsole{$ENDIF}];
    {$IFNDEF DEBUG}
    fServer.ShowWindow := swoHIDE;
    {$ENDIF}
    if fPortNum <> 0 then
      fServer.Parameters.Add('-p' + intToStr(port));
  end;
  fTempLines := TStringList.Create;
  fImportCache := TStringHashSet.Create;

  if fServer.isNotNil then
  begin
    fServer.Execute;
    while true do
    begin
      if (i = 10) or checkDcdSocket then
        break;
      i += 1;
    end;
  end;
  updateServerlistening;
  //
  EntitiesConnector.addObserver(self);
end;

class function TCEDcdWrapper.noDcdPassedAsArg(): boolean;
var
  i: integer;
begin
  result := false;
  for i := 1 to argc-1 do
    if ParamStr(i) = '-nodcd' then
  begin
    result :=true;
    break;
  end;
end;

class procedure TCEDcdWrapper.relaunch;
begin
  fDcdWrapper.Free;
  fDcdWrapper := TCEDcdWrapper.create(nil);
end;

function TCEDcdWrapper.getIfLaunched: boolean;
begin
  result := fServer.isNotNil;
end;

procedure TCEDcdWrapper.updateServerlistening;
begin
  fServerListening := AppIsRunning((serverName));
end;

destructor TCEDcdWrapper.destroy;
var
  i: integer = 0;
begin
  saveToFile(getCoeditDocPath + optsname);
  EntitiesConnector.removeObserver(self);
  fImportCache.Free;
  if fTempLines.isNotNil then
    fTempLines.Free;
  if fServer.isNotNil then
  begin
    if not fServerWasRunning then
    begin
      killServer;
      while true do
      begin
        if (not checkDcdSocket) or (i = 10) then
          break;
        i +=1;
      end;
    end;
    fServer.Terminate(0);
    fServer.Free;
  end;
  fClient.Free;
  inherited;
end;
{$ENDREGION}

{$REGION ICEProjectObserver ----------------------------------------------------}
procedure TCEDcdWrapper.projNew(project: ICECommonProject);
begin
  fProj := project;
end;

procedure TCEDcdWrapper.projChanged(project: ICECommonProject);
var
  i: Integer;
  fold: string;
  folds: TStringList;
begin
  if (fProj = nil) or (fProj <> project) then
    exit;

  folds := TStringList.Create;
  try
    fold := ce_projutils.projectSourcePath(project);
    if fold.dirExists then
      folds.Add(fold);
  	for i := 0 to fProj.importsPathCount-1 do
  	begin
    	fold := fProj.importPath(i);
      if fold.dirExists and (folds.IndexOf(fold) = -1) then
        folds.Add(fold);
    end;
    addImportFolders(folds);
  finally
    folds.Free;
  end;
end;

procedure TCEDcdWrapper.projClosing(project: ICECommonProject);
begin
  if fProj <> project then
    exit;
  fProj := nil;
end;

procedure TCEDcdWrapper.projFocused(project: ICECommonProject);
begin
  fProj := project;
end;

procedure TCEDcdWrapper.projCompiling(project: ICECommonProject);
begin
end;

procedure TCEDcdWrapper.projCompiled(project: ICECommonProject; success: boolean);
begin
end;
{$ENDREGION}

{$REGION ICEDocumentObserver ---------------------------------------------------}
procedure TCEDcdWrapper.docNew(document: TCESynMemo);
begin
  fDoc := document;
end;

procedure TCEDcdWrapper.docFocused(document: TCESynMemo);
begin
  fDoc := document;
end;

procedure TCEDcdWrapper.docChanged(document: TCESynMemo);
begin
  if fDoc <> document then exit;
end;

procedure TCEDcdWrapper.docClosing(document: TCESynMemo);
begin
  if fDoc <> document then exit;
  fDoc := nil;
end;
{$ENDREGION}

{$REGION DCD things ------------------------------------------------------------}
procedure TCEDcdWrapper.terminateClient;
begin
  if fClient.Running then
    fClient.Terminate(0);
end;

function TCEDcdWrapper.checkDcdSocket: boolean;
var
  str: string;
  {$IFDEF WINDOWS}
  prt: word = 9166;
  prc: TProcess;
  lst: TStringList;
  {$ENDIF}
begin
  sleep(100);
  // nix/osx: the file might exists from a previous session that crashed
  // however the 100 ms might be enough for DCD to initializes
  {$IFDEF LINUX}
  str := sysutils.GetEnvironmentVariable('XDG_RUNTIME_DIR');
  if (str + DirectorySeparator + 'dcd.socket').fileExists then
    exit(true);
  str := sysutils.GetEnvironmentVariable('UID');
  if ('/tmp/dcd-' + str + '.socket').fileExists then
    exit(true);
  {$ENDIF}
  {$IFDEF DARWIN}
  str := sysutils.GetEnvironmentVariable('UID');
  if ('/var/tmp/dcd-' + str + '.socket').fileExists then
    exit(true);
  {$ENDIF}
  {$IFDEF WINDOWS}
  result := false;
  if port <> 0 then prt := port;
  prc := TProcess.Create(nil);
  try
    prc.Options:= [poUsePipes, poNoConsole];
    prc.Executable := 'netstat';
    prc.Parameters.Add('-o');
    prc.Parameters.Add('-a');
    prc.Parameters.Add('-n');
    prc.Execute;
    lst := TStringList.Create;
    try
      processOutputToStrings(prc,lst);
      for str in lst do
      if AnsiContainsText(str, '127.0.0.1:' + intToStr(prt))
      and AnsiContainsText(str, 'TCP')
      and AnsiContainsText(str, 'LISTENING') then
      begin
        result := true;
        break;
      end;
    finally
      lst.Free;
    end;
  finally
    prc.Free;
  end;
  exit(result);
  {$ENDIF}
  exit(false);
end;

procedure TCEDcdWrapper.killServer;
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  //
  fClient.Parameters.Clear;
  fClient.Parameters.Add('--shutdown');
  fClient.Execute;
  while fServer.Running or fClient.Running do
    sleep(50);
end;

procedure TCEDcdWrapper.waitClient;
begin
  while fClient.Running do
    sleep(5);
end;

procedure TCEDcdWrapper.writeSourceToInput;
begin
  fInputSource := fDoc.Strings.TextString_UTF8;
  fClient.Input.Write(fInputSource[1], fInputSource.length);
  fClient.CloseInput;
end;

procedure TCEDcdWrapper.addImportFolder(const folder: string);
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  //
  if fImportCache.contains(folder) then
    exit;
  fImportCache.insert(folder);
  fClient.Parameters.Clear;
  fClient.Parameters.Add('-I' + folder);
  fClient.Execute;
  while fClient.Running do ;
end;

procedure TCEDcdWrapper.addImportFolders(const folders: TStrings);
var
  imp: string;
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  //
  fClient.Parameters.Clear;
  for imp in folders do
  begin
    if fImportCache.contains(imp) then
      continue;
    fImportCache.insert(imp);
    fClient.Parameters.Add('-I' + imp);
  end;
  if fClient.Parameters.Count <> 0 then
  begin
    fClient.Execute;
  end;
  while fClient.Running do ;
end;

procedure TCEDcdWrapper.getCallTip(out tips: string);
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  if fDoc = nil then exit;
  //
  terminateClient;
  //
  fClient.Parameters.Clear;
  fClient.Parameters.Add('-c');
  fClient.Parameters.Add(intToStr(fDoc.caretBytePosition));
  fClient.Execute;
  writeSourceToInput;
  //
  fTempLines.Clear;
  processOutputToStrings(fClient, fTempLines);
  while fClient.Running do ;
  if fTempLines.Count = 0 then
  begin
    updateServerlistening;
    exit;
  end;
  if not (fTempLines[0] = 'calltips') then exit;
  //
  fTempLines.Delete(0);
  tips := fTempLines.Text;
  {$IFDEF WINDOWS}
  tips := tips[1..tips.length-2];
  {$ELSE}
  tips := tips[1..tips.length-1];
  {$ENDIF}
end;

function compareknd(List: TStringList; Index1, Index2: Integer): Integer;
var
  k1, k2: byte;
begin
  k1 := Byte(PtrUint(List.Objects[Index1]));
  k2 := Byte(PtrUint(List.Objects[Index2]));
  if k1 > k2 then
    result := 1
  else if k1 < k2 then
    result := -1
  else
    result := CompareStr(list[Index1], list[Index2]);
end;

procedure TCEDcdWrapper.getComplAtCursor(list: TStringList);
var
  i: Integer;
  kind: Char;
  item: string;
  kindObj: TObject = nil;
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  if fDoc = nil then exit;
  //
  terminateClient;
  //
  fClient.Parameters.Clear;
  fClient.Parameters.Add('-c');
  fClient.Parameters.Add(intToStr(fDoc.caretBytePosition));
  fClient.Execute;
  writeSourceToInput;
  //
  fTempLines.Clear;
  processOutputToStrings(fClient, fTempLines);
  while fClient.Running do ;
  if fTempLines.Count = 0 then
  begin
    updateServerlistening;
    exit;
  end;
  if not (fTempLines[0] = 'identifiers') then exit;
  //
  list.Clear;
  for i := 1 to fTempLines.Count-1 do
  begin
    item := fTempLines[i];
    kind := item[item.length];
    setLength(item, item.length-2);
    case kind of
      'c': kindObj := TObject(PtrUint(dckClass));
      'i': kindObj := TObject(PtrUint(dckInterface));
      's': kindObj := TObject(PtrUint(dckStruct));
      'u': kindObj := TObject(PtrUint(dckUnion));
      'v': kindObj := TObject(PtrUint(dckVariable));
      'm': kindObj := TObject(PtrUint(dckMember));
      'k': kindObj := TObject(PtrUint(dckReserved));
      'f': kindObj := TObject(PtrUint(dckFunction));
      'g': kindObj := TObject(PtrUint(dckEnum));
      'e': kindObj := TObject(PtrUint(dckEnum_member));
      'P': kindObj := TObject(PtrUint(dckPackage));
      'M': kindObj := TObject(PtrUint(dckModule));
      'a': kindObj := TObject(PtrUint(dckArray));
      'A': kindObj := TObject(PtrUint(dckAA));
      'l': kindObj := TObject(PtrUint(dckAlias));
      't': kindObj := TObject(PtrUint(dckTemplate));
      'T': kindObj := TObject(PtrUint(dckMixin));
      // internal DCD stuff, Should not to happen...report bug if it does.
      '*', '?': continue;
    end;
    list.AddObject(item, kindObj);
  end;
  //list.CustomSort(@compareknd);
end;

procedure TCEDcdWrapper.getDdocFromCursor(out comment: string);
var
  i: Integer;
  len: Integer;
  str: string;
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  if fDoc = nil then exit;
  //
  i := fDoc.MouseBytePosition;
  if i = 0 then exit;
  //
  terminateClient;
  //
  fClient.Parameters.Clear;
  fClient.Parameters.Add('-d');
  fClient.Parameters.Add('-c');
  fClient.Parameters.Add(intToStr(i - 1));
  fClient.Execute;
  writeSourceToInput;
  //
  comment := '';
  fTempLines.Clear;
  processOutputToStrings(fClient, fTempLines);
  while fClient.Running do ;
  len := fTempLines.Count-1;
  if len = -1 then
    updateServerlistening;
  for i := 0 to len do
  begin
    str := fTempLines[i];
    with TStringRange.create(str) do while not empty do
    begin
      comment += takeUntil('\').yield;
      if startsWith('\\') then
      begin
        comment += '\';
        popFrontN(2);
      end
      else if startsWith('\n') then
      begin
        comment += LineEnding;
        popFrontN(2);
      end
    end;
    if i <> len then
      comment += LineEnding + LineEnding;
  end;
end;

procedure TCEDcdWrapper.getDeclFromCursor(out fname: string; out position: Integer);
var
   i: Integer;
   str, loc: string;
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  if fDoc = nil then exit;
  //
  terminateClient;
  //
  fClient.Parameters.Clear;
  fClient.Parameters.Add('-l');
  fClient.Parameters.Add('-c');
  fClient.Parameters.Add(intToStr(fDoc.caretBytePosition));
  fClient.Execute;
  writeSourceToInput;
  //
  fTempLines.Clear;
  processOutputToStrings(fClient, fTempLines);
  while fClient.Running do ;
  if fTempLines.Count > 0 then
  begin
    str := fTempLines[0];
    if str.isNotEmpty then
    begin
      i := Pos(#9, str);
      if i = -1 then
        exit;
      loc := str[i+1..str.length];
      fname := TrimFilename(str[1..i-1]);
      loc := ReplaceStr(loc, LineEnding, '');
      position := strToIntDef(loc, -1);
    end;
  end
  else updateServerlistening;
end;

procedure TCEDcdWrapper.getLocalSymbolUsageFromCursor(var locs: TIntOpenArray);
var
   i: Integer;
   str: string;
begin
  if not fAvailable then exit;
  if not fServerListening then exit;
  if fDoc = nil then exit;
  //
  terminateClient;
  //
  fClient.Parameters.Clear;
  fClient.Parameters.Add('-u');
  fClient.Parameters.Add('-c');
  fClient.Parameters.Add(intToStr(fDoc.caretBytePosition));
  fClient.Execute;
  writeSourceToInput;
  //
  setLength(locs, 0);
  fTempLines.Clear;
  processOutputToStrings(fClient, fTempLines);
  while fClient.Running do ;
  if fTempLines.Count < 2 then
    exit;
  str := fTempLines[0];
  // symbol is not in current module, too complex for now
  if str[1..5] <> 'stdin' then
    exit;
  //
  setLength(locs, fTempLines.count-1);
  for i:= 1 to fTempLines.count-1 do
    locs[i-1] := StrToIntDef(fTempLines[i], -1);
end;
{$ENDREGION}

function DCDWrapper: TCEDcdWrapper;
begin
  if fDcdWrapper.isNil then
    fDcdWrapper := TCEDcdWrapper.create(nil);
  exit(fDcdWrapper);
end;

finalization
  DcdWrapper.Free;
end.
