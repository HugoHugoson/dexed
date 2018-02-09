unit ce_tools;

{$I ce_defines.inc}

interface

uses
  Classes, SysUtils, LazFileUtils, process, menus, ce_processes, controls,
  ce_common, ce_writableComponent, ce_interfaces, ce_observer, ce_inspectors,
  ce_synmemo, ce_dialogs;

type

  TCEToolItems = class;

  TPipeInputKind = (pikNone, pikEditor, pikSelection, pikLine);

  TCEToolItem = class(TCollectionItem)
  private
    fToolItems: TCEToolItems;
    fNextToolAlias: string;
    fProcess: TCEProcess;
    fExecutable: TCEFilename;
    fWorkingDir: TCEPathname;
    fShowWin: TShowWindowOptions;
    fOpts: TProcessOptions;
    fParameters: TStringList;
    fToolAlias: string;
    fQueryParams: boolean;
    fClearMessages: boolean;
    fOutputToNext: boolean;
    fShortcut: TShortcut;
    fMsgs: ICEMessagesDisplay;
    fSymStringExpander: ICESymStringExpander;
    fPipeInputKind: TPipeInputKind;
    fAskConfirmation: boolean;
    procedure setParameters(value: TStringList);
    procedure processOutput(sender: TObject);
    procedure setToolAlias(value: string);
  published
    property toolAlias: string read fToolAlias write setToolAlias;
    property options: TProcessOptions read fOpts write fOpts;
    property executable: TCEFilename read fExecutable write fExecutable;
    property workingDirectory: TCEPathname read fWorkingDir write fWorkingDir;
    property parameters: TStringList read fParameters write setParameters;
    property showWindows: TShowWindowOptions read fShowWin write fShowWin;
    property queryParameters: boolean read fQueryParams write fQueryParams;
    property clearMessages: boolean read fClearMessages write fClearMessages;
    property shortcut: TShortcut read fShortcut write fShortcut;
    property nextToolAlias: string read fNextToolAlias write fNextToolAlias;
    property outputToNext: boolean read fOutputToNext write fOutputToNext;
    property pipeInputKind: TPipeInputKind read fPipeInputKind write fPipeInputKind;
    property askConfirmation: boolean read fAskConfirmation write fAskConfirmation;
  public
    constructor create(ACollection: TCollection); override;
    destructor destroy; override;
    procedure assign(Source: TPersistent); override;
    procedure execute(previous: TCEToolItem);
    property process: TCEProcess read fProcess;
  end;

  TCEToolItems = class(TCollection)
  public
    function findTool(const value: string): TCEToolItem;
  end;

  TCETools = class(TWritableLfmTextComponent, ICEEditableShortcut, ICEDocumentObserver)
  private
    fTools: TCEToolItems;
    fShctCount: Integer;
    fDoc: TCESynMemo;
    fMenu: TMenuItem;
    fReadOnly: boolean;
    function getTool(index: Integer): TCEToolItem;
    procedure setTools(value: TCEToolItems);
    //
    procedure executeToolFromMenu(sender: TObject);
    //
    procedure docNew(document: TCESynMemo);
    procedure docFocused(document: TCESynMemo);
    procedure docChanged(document: TCESynMemo);
    procedure docClosing(document: TCESynMemo);
    //
    function scedWantFirst: boolean;
    function scedWantNext(out category, identifier: string; out aShortcut: TShortcut): boolean;
    procedure scedSendItem(const category, identifier: string; aShortcut: TShortcut);
    procedure scedSendDone;
  published
    property tools: TCEToolItems read fTools write setTools;
    property readOnly: boolean read fReadOnly write fReadOnly;
  public
    constructor create(aOwner: TComponent); override;
    destructor destroy; override;
    //
    procedure updateMenu;
    function addTool: TCEToolItem;
    procedure executeTool(tool: TCEToolItem); overload;
    procedure executeTool(index: Integer); overload;
    property tool[index: integer]: TCEToolItem read getTool; default;
  end;

//TODO-crefactor: either set the tools as a service of merge the tools collection& tool editor in a single unit.

var
  CustomTools: TCETools;

implementation

uses
  dialogs;

const
  toolsFname = 'tools.txt';

{$REGION TCEToolItem -----------------------------------------------------------}
function TCEToolItems.findTool(const value: string): TCEToolItem;
var
  item: TCollectionItem;
begin
  for item in self do
    if TCEToolItem(item).toolAlias = value then
      exit(TCEToolItem(item));
  exit(nil);
end;

constructor TCEToolItem.create(ACollection: TCollection);
begin
  inherited;
  // TODO-cbugfix: tools are init before symstring, even when order of 'uses' is modified (lpr)
  fSymStringExpander:= getSymStringExpander;
  fMsgs       := getMessageDisplay;
  fToolItems  := TCEToolItems(ACollection);
  fToolAlias  := format('<tool %d>', [ID]);
  fParameters := TStringList.create;
end;

destructor TCEToolItem.destroy;
begin
  fParameters.Free;
  ce_processes.killProcess(fProcess);
  inherited;
end;

procedure TCEToolItem.assign(Source: TPersistent);
var
  tool: TCEToolItem;
begin
  // only used to clone a tool: so don't copy everything.
  if Source is TCEToolItem then
  begin
    tool := TCEToolItem(Source);
    toolAlias         := tool.toolAlias;
    queryParameters   := tool.queryParameters;
    clearMessages     := tool.clearMessages;
    options           := tool.options;
    executable        := tool.executable;
    workingDirectory  := tool.workingDirectory;
    showWindows       := tool.showWindows;
    pipeInputKind     := tool.pipeInputKind;
    askConfirmation   := tool.askConfirmation;
    parameters.Assign(tool.parameters);
  end
  else inherited;
end;

procedure TCEToolItem.setParameters(value: TStringList);
begin
  fParameters.Assign(value);
end;

procedure TCEToolItem.setToolAlias(value: string);
var
  i: integer = 0;
begin
  while fToolItems.findTool(value).isNotNil do
  begin
    value += intToStr(i);
    i += 1;
  end;
  fToolAlias := value;
end;

procedure TCEToolItem.execute(previous: TCEToolItem);
var
  arg: string;
  prm: string;
  inp: string;
  old: string;
const
  confSpec = 'Are you sure you want to execute the "%s" tool ?';
begin
  ce_processes.killProcess(fProcess);

  if fMsgs = nil then
    fMsgs := getMessageDisplay;
  if fClearMessages then
    fMsgs.clearByContext(amcMisc);
  if fSymStringExpander = nil then
    fSymStringExpander:= getSymStringExpander;

  if askConfirmation and (dlgOkCancel(format(confSpec, [toolAlias])) <> mrOk) then
    exit;

  old := GetCurrentDirUTF8;
  fProcess := TCEProcess.Create(nil);
  fProcess.OnReadData:= @processOutput;
  fProcess.OnTerminate:= @processOutput;
  fProcess.Options := fOpts;
  fProcess.Executable := exeFullName(fSymStringExpander.expand(fExecutable));
  fProcess.ShowWindow := fShowWin;
  fProcess.CurrentDirectory := fSymStringExpander.expand(fWorkingDir);
  fProcess.XTermProgram:=consoleProgram;
  for prm in fParameters do if not isStringDisabled(prm) then
    fProcess.Parameters.AddText(fSymStringExpander.expand(prm));
  if fQueryParams then
  begin
    prm := '';
    if InputQuery('Parameters', '', prm) then
    begin
      prm := fSymStringExpander.expand(prm);
      arg := StringReplace(fParameters.Text, '<$1>', prm, [rfReplaceAll]);
      if prm.isNotEmpty and (arg = fParameters.Text) then
        fProcess.Parameters.AddText(prm)
      else
        fProcess.Parameters.Text := arg;
    end;
  end;
  ensureNoPipeIfWait(fProcess);
  //
  if fProcess.Executable.fileExists then
  begin
    fProcess.Execute;
    if previous.isNotNil and previous.outputToNext
      and (poUsePipes in previous.Options) and (poUsePipes in Options) then
    begin
      setLength(inp, previous.process.OutputStack.Size);
      previous.process.OutputStack.Position:=0;
      previous.process.OutputStack.Read(inp[1], inp.length);
      fProcess.Input.Write(inp[1], inp.length);
      fProcess.CloseInput;
    end;
  end;
  //
  SetCurrentDirUTF8(old);
end;

procedure TCEToolItem.processOutput(sender: TObject);
var
  lst: TStringList;
  str: string;
  nxt: TCEToolItem;
begin
  if ((not fOutputToNext) or fNextToolAlias.isEmpty) and (poUsePipes in options) then
  begin
    lst := TStringList.Create;
    try
      fProcess.getFullLines(lst);
      for str in lst do
        fMsgs.message(str, nil, amcMisc, amkAuto);
    finally
      lst.Free;
    end;
  end;
  if (not fProcess.Running) then
  begin
    if fProcess.ExitStatus > 0 then
    begin
      fMsgs.message(format('error: the tool (%s) has returned the status %s',
        [fProcess.Executable, prettyReturnStatus(fProcess)]), nil, amcMisc, amkErr);
      ce_processes.killProcess(fProcess);
      exit;
    end;
    if fNextToolAlias.isNotEmpty then
    begin
      nxt := fToolItems.findTool(fNextToolAlias);
      if nxt.isNotNil then
        nxt.execute(self);
    end;
  end;
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION Standard Comp/Obj -----------------------------------------------------}
constructor TCETools.create(aOwner: TComponent);
var
  fname: string;
begin
  inherited;
  fTools := TCEToolItems.Create(TCEToolItem);
  fname := getCoeditDocPath + toolsFname;
  if fname.fileExists then
    loadFromFile(fname);

  EntitiesConnector.addObserver(self);
end;

destructor TCETools.destroy;
begin
  EntitiesConnector.removeObserver(self);

  ForceDirectoriesUTF8(getCoeditDocPath);
  saveToFile(getCoeditDocPath + toolsFname);
  fTools.Free;
  inherited;
end;
{$ENDREGION}

{$REGION ICEMainMenuProvider ---------------------------------------------------}
procedure TCETools.updateMenu;
var
  mnu: ICEMainMenu = nil;
  itm: TMenuItem;
  colitm: TCEToolItem;
  i: integer;
begin
  if fMenu.isNil then
  begin
    mnu := getMainMenu;
    if not assigned(mnu) then
      exit;
    fMenu := mnu.mnuAdd;
    fMenu.Caption:='Custom tools';
  end;
  fMenu.Clear;
  for i := 0 to tools.Count-1 do
  begin
    colitm := tool[i];
    itm := TMenuItem.Create(fMenu);
    itm.ShortCut:= colitm.shortcut;
    itm.Caption := colitm.toolAlias;
    itm.tag := ptrInt(colitm);
    itm.onClick := @executeToolFromMenu;
    fMenu.add(itm);
  end;
end;

procedure TCETools.executeToolFromMenu(sender: TObject);
begin
  executeTool(TCEToolItem(TMenuItem(sender).tag));
end;
{$ENDREGION}

{$REGION ICEEditableShortcut ---------------------------------------------------}
function TCETools.scedWantFirst: boolean;
begin
  result := fTools.Count > 0;
  fShctCount := 0;
end;

function TCETools.scedWantNext(out category, identifier: string; out aShortcut: TShortcut): boolean;
begin
  category  := 'Tools';
  identifier:= tool[fShctCount].toolAlias;
  aShortcut := tool[fShctCount].shortcut;
  //
  fShctCount += 1;
  result := fShctCount < fTools.Count;
end;

procedure TCETools.scedSendItem(const category, identifier: string; aShortcut: TShortcut);
var
  i: Integer;
begin
 if category <> 'Tools' then exit;
 //
 for i := 0 to tools.Count-1 do if tool[i].toolAlias = identifier then
 begin
   tool[i].shortcut := aShortcut;
   break;
 end;
end;

procedure TCETools.scedSendDone;
begin
end;
{$ENDREGION}

{$REGION ICEDocumentObserver ---------------------------------------------------}
procedure TCETools.docNew(document: TCESynMemo);
begin
  fDoc := document;
end;

procedure TCETools.docFocused(document: TCESynMemo);
begin
  fDoc := document;
end;

procedure TCETools.docChanged(document: TCESynMemo);
begin
end;

procedure TCETools.docClosing(document: TCESynMemo);
begin
  if fDoc <> document then exit;
  fDoc := nil;
end;
{$ENDREGION}

{$REGION Tools things ----------------------------------------------------------}
procedure TCETools.setTools(value: TCEToolItems);
begin
  fTools.Assign(value);
end;

function TCETools.getTool(index: Integer): TCEToolItem;
begin
  result := TCEToolItem(fTools.Items[index]);
end;

function TCETools.addTool: TCEToolItem;
begin
  result := TCEToolItem(fTools.Add);
end;

procedure TCETools.executeTool(tool: TCEToolItem);
var
  txt: string = '';
begin
  if tool.isNil then exit;
  //
  tool.execute(nil);
  if (tool.pipeInputKind <> pikNone) and fDoc.isNotNil
    and (poUsePipes in tool.options) and tool.fProcess.Input.isNotNil then
  begin
    case tool.pipeInputKind of
      pikEditor:    txt := fDoc.Strings.TextString_UTF8;
      pikLine:      txt := fDoc.lineTextAtCarret();
      pikSelection: txt := fDoc.selTextUTF8;
    end;
    if txt.isNotEmpty then
       tool.fProcess.Input.Write(txt[1], txt.length);
    tool.fProcess.CloseInput;
  end;
end;

procedure TCETools.executeTool(index: Integer);
begin
  if index < 0 then exit;
  if index > fTools.Count-1 then exit;
  //
  executeTool(tool[index]);
end;
{$ENDREGION}

initialization
  CustomTools := TCETools.create(nil);
finalization
  CustomTools.Free;
end.
