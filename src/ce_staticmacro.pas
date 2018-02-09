unit ce_staticmacro;

{$I ce_defines.inc}

interface

uses
  Classes, Sysutils, SynEdit, SynCompletion, RegExpr,
  ce_common, ce_interfaces, ce_writableComponent, ce_synmemo;

type


  (**
   * Static macros options containers
   *)
  TStaticMacrosOptions = class(TWritableLfmTextComponent)
  private
    fAutoInsert: boolean;
    fShortCut: TShortCut;
    fMacros: TStringList;
    fSetDef: TCEEditEvent;
    procedure setMacros(value: TStringList);
    procedure setDefEvent(value: TCEEditEvent);
  published
    property autoInsert: boolean read fAutoInsert write fAutoInsert;
    property macros: TStringList read fMacros write setMacros;
    property shortcut: TShortCut read fShortCut write fShortCut;
    property resetDefault: TCEEditEvent read fSetDef write setDefEvent stored false;
	public
    constructor create(aOwner: TComponent); override;
    destructor destroy; override;
    procedure Assign(Source: TPersistent); override;
    procedure AssignTo(target: TPersistent); override;
  end;

  (**
   * TCEStaticEditorMacro is used to insert static macros (parameter-less code snippets)
   * in an editor. A macro begins with the dollar symbol and ends with an alphanum.
   *
   * The dollar symbol is used as starter because it's usually accessible without
   * modifier: no CTRL, no ALT, no SHIFT.
   * Erroneous insertion is avoided because in D '$' is either followed
   * by a symbol: '$-1', '$]' or by a blank '$ ]'
   *
   * Shift + SPACE works automatically on the right editor (ICEDocumentObserver)
   * Automatic insertion is handled in TCESynMemo.KeyUp()
   *)
  TCEStaticEditorMacro = class(TWritableLfmTextComponent, ICEDocumentObserver, ICEEditableOptions, ICEEditableShortCut)
  private
    fValidator: TRegExpr;
    fCompletor: TSynAutoComplete;
    fMacros: TStringList;
    fDoc: TCESynMemo;
    fAutomatic: boolean;
    fOptions: TStaticMacrosOptions;
    fOptionBackup: TStaticMacrosOptions;
    procedure sanitize;
    procedure addDefaults;
    procedure updateCompletor;
    procedure setMacros(value: TStringList);
    // ICEDocumentObserver
    procedure docNew(document: TCESynMemo);
    procedure docFocused(document: TCESynMemo);
    procedure docChanged(document: TCESynMemo);
    procedure docClosing(document: TCESynMemo);
    // ICEEditableOptions
    function optionedWantCategory(): string;
    function optionedWantEditorKind: TOptionEditorKind;
    function optionedWantContainer: TPersistent;
    procedure optionedEvent(event: TOptionEditorEvent);
    function optionedOptionsModified: boolean;
    // ICEEditableShortcut
    function scedWantFirst: boolean;
    function scedWantNext(out category, identifier: string; out aShortcut: TShortcut): boolean;
    procedure scedSendItem(const category, identifier: string; aShortcut: TShortcut);
    procedure scedSendDone;
  published
    // list of string with the format $<..>alnum=<..>
    property macros: TStringList read fMacros write setMacros;
    property automatic: boolean read fAutomatic write fAutomatic;
  public
    constructor create(aOwner: TComponent); override;
    destructor destroy; override;
    // execute using the editor
    procedure Execute; overload;
    // execute in aEditor, according to aToken
    procedure Execute(aEditor: TCustomSynEdit; const aToken: string); overload;
  end;

var
  StaticEditorMacro: TCEStaticEditorMacro = nil;

implementation

uses
  ce_observer;

const
  OptFname = 'staticmacros.txt';

  defMacros: array[0..15] of string = (
    '$a=auto',
    '$b={}',
    '$c=class {}',
    '$e=enum {}',
    '$it=interface {}',
    '$im=import ',
    '$pr=protected {}',
    '$pu=public {}',
    '$pv=private {}',
    '$s=struct {}',
    '$t=template {}',
    '$un=union{}',
    '$ut=unittest{}',
    '$fo=for(auto i = 0; ; )',
    '$fe=foreach(elem; )',
    '$v=void (){}'
  );

{$REGION TStaticMacrosOptions --------------------------------------------------}

constructor TStaticMacrosOptions.create(aOwner: TComponent);
begin
	inherited;
  fMacros := TStringList.Create;
end;

destructor TStaticMacrosOptions.destroy;
begin
  fMacros.Free;
  inherited;
end;

procedure TStaticMacrosOptions.Assign(Source: TPersistent);
var
  edmac: TCEStaticEditorMacro;
  opt: TStaticMacrosOptions;
begin
	if Source is TCEStaticEditorMacro then
  begin
    edmac := TCEStaticEditorMacro(Source);
    //
    fAutoInsert := edmac.automatic;
    fMacros.Assign(edmac.fMacros);
    fShortCut := edmac.fCompletor.ShortCut;
  end
  else if Source is  TStaticMacrosOptions then
  begin
    opt := TStaticMacrosOptions(Source);
    //
    autoInsert := opt.autoInsert;
    macros.Assign(opt.fMacros);
    shortcut := opt.shortcut;
  end
  else inherited;
end;

procedure TStaticMacrosOptions.AssignTo(target: TPersistent);
var
  edmac: TCEStaticEditorMacro;
  opt: TStaticMacrosOptions;
begin
	if target is TCEStaticEditorMacro then
  begin
    edmac := TCEStaticEditorMacro(target);
    //
    edmac.automatic := fAutoInsert;
    // setMacros sanitizes the macros
    edmac.setMacros(fMacros);
    fMacros.Assign(edmac.fMacros);
    //
    edmac.fCompletor.ShortCut := fShortCut;
  end
  else if target is  TStaticMacrosOptions then
  begin
    opt := TStaticMacrosOptions(target);
    //
    opt.autoInsert := autoInsert;
    opt.macros.Assign(fMacros);
    opt.shortcut := shortcut;
  end
  else inherited;
end;

procedure TStaticMacrosOptions.setMacros(value: TStringList);
begin
  fMacros.Assign(value);
end;

procedure TStaticMacrosOptions.setDefEvent(value : TCEEditEvent);
begin
  TCEStaticEditorMacro(owner).addDefaults;
  fMacros.Assign(TCEStaticEditorMacro(owner).fMacros);
end;
{$ENDREGION}

{$REGION Standard Comp/Obj -----------------------------------------------------}
constructor TCEStaticEditorMacro.create(aOwner: TComponent);
var
  fname: string;
begin
  inherited;
  fAutomatic := true;
  fValidator := TRegExpr.Create('^\$\w*[a-zA-Z]$');
  fValidator.Compile;
  fCompletor := TSynAutoComplete.Create(self);
  fCompletor.ShortCut := 8224; // SHIFT + SPACE
  fCompletor.EndOfTokenChr:= '';
  fMacros := TStringList.Create;
  fMacros.Delimiter := '=';
  //
  fOptions := TStaticMacrosOptions.create(self);
  fOptionBackup := TStaticMacrosOptions.create(self);
  fname := getCoeditDocPath + OptFname;
  if fname.fileExists then
  begin
    fOptions.loadFromFile(fname);
    // old option file will create a streaming error.
    if fOptions.hasLoaded then
    	fOptions.AssignTo(self)
    else
    	fOptions.Assign(self);
  end
  else
  begin
    addDefaults;
    fOptions.Assign(self);
  end;
  //
  sanitize;
  updateCompletor;
  //
  EntitiesConnector.addObserver(Self);
end;

destructor TCEStaticEditorMacro.destroy;
begin
  fOptions.saveToFile(getCoeditDocPath + OptFname);
  EntitiesConnector.removeObserver(Self);
  //
  fMacros.Free;
  fValidator.Free;
  inherited;
end;

procedure TCEStaticEditorMacro.setMacros(value: TStringList);
begin
  fMacros.Assign(value);
  sanitize;
  updateCompletor;
end;
{$ENDREGION}

{$REGION ICEDocumentObserver ---------------------------------------------------}
procedure TCEStaticEditorMacro.docNew(document: TCESynMemo);
begin
  fDoc := document;
  //fCompletor.Editor := fDoc;
end;

procedure TCEStaticEditorMacro.docFocused(document: TCESynMemo);
begin
  if fDoc = document then exit;
  fDoc := document;
  //fCompletor.Editor := fDoc;
end;

procedure TCEStaticEditorMacro.docChanged(document: TCESynMemo);
begin
  if document <> fDoc then
    exit;
end;

procedure TCEStaticEditorMacro.docClosing(document: TCESynMemo);
begin
  if document <> fDoc then
    exit;
  fDoc := nil;
end;
{$ENDREGION}

{$REGION ICEEditableOptions ----------------------------------------------------}
function TCEStaticEditorMacro.optionedWantCategory(): string;
begin
	exit('Static macros');
end;

function TCEStaticEditorMacro.optionedWantEditorKind: TOptionEditorKind;
begin
	exit(oekGeneric);
end;

function TCEStaticEditorMacro.optionedWantContainer: TPersistent;
begin
	fOptions.Assign(self);
  fOptionBackup.Assign(fOptions);
  exit(fOptions);
end;

procedure TCEStaticEditorMacro.optionedEvent(event: TOptionEditorEvent);
begin
	case event of
    oeeAccept:
    begin
      fOptions.AssignTo(self);
      fOptionBackup.Assign(self);
    end;
    oeeCancel:
    begin
      fOptionBackup.AssignTo(self);
      fOptionBackup.AssignTo(fOptions);
    end;
    oeeChange: fOptions.AssignTo(self);
  end;
end;

function TCEStaticEditorMacro.optionedOptionsModified: boolean;
begin
  exit(false);
end;
{$ENDREGION}

{$REGION ICEEditableShortCut ---------------------------------------------------}
function TCEStaticEditorMacro.scedWantFirst: boolean;
begin
  exit(true);
end;

function TCEStaticEditorMacro.scedWantNext(out category, identifier: string; out aShortcut: TShortcut): boolean;
begin
  category := 'Static macros';
  identifier := 'invoke';
  aShortcut := fCompletor.ShortCut;
  exit(false);
end;

procedure TCEStaticEditorMacro.scedSendItem(const category, identifier: string; aShortcut: TShortcut);
begin
  if category = 'Static macros' then
    if identifier = 'invoke' then begin
      fCompletor.ShortCut := aShortcut;
      fOptionBackup.shortcut := aShortcut;
      fOptions.shortcut := aShortcut;
    end;
end;

procedure TCEStaticEditorMacro.scedSendDone;
begin
end;
{$ENDREGION}

{$REGION Macros things ---------------------------------------------------------}
procedure TCEStaticEditorMacro.sanitize;
var
  i: Integer;
begin
  for i := fMacros.Count-1 downto 0 do
    if not fValidator.Exec(fMacros.Names[i]) then
      fMacros.Delete(i);
end;

procedure TCEStaticEditorMacro.addDefaults;
var
  i: Integer;
begin
  for i := 0 to high(defMacros) do
    if fMacros.IndexOf(defMacros[i]) = -1 then
      fMacros.Add(defMacros[i]);
end;

procedure TCEStaticEditorMacro.updateCompletor;
var
  i: Integer;
  tok, val: string;
begin
  fCompletor.AutoCompleteList.Clear;
  for i := 0 to fMacros.Count-1 do
  begin
    tok := fMacros.Names[i];
    val := fMacros.ValueFromIndex[i];
    fCompletor.AutoCompleteList.Add(tok);
    fCompletor.AutoCompleteList.Add('=' + val);
  end;
end;

procedure TCEStaticEditorMacro.Execute;
begin
  //if fDoc.isNotNil then
  //  fCompletor.Execute(fDoc.Identifier, fDoc);
end;

procedure TCEStaticEditorMacro.Execute(aEditor: TCustomSynEdit; const aToken: string);
begin
  if aEditor.isNotNil then
    fCompletor.Execute(aToken, aEditor);
end;
{$ENDREGION}

initialization
  StaticEditorMacro := TCEStaticEditorMacro.create(nil);
finalization
  StaticEditorMacro.Free;;
end.

