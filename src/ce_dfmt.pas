unit ce_dfmt;

{$I ce_defines.inc}

interface

uses
  Classes, SysUtils, FileUtil, RTTIGrids, Forms, Controls, Graphics, ExtCtrls,
  Menus, Buttons, process, SynEditKeyCmds, ce_widget, ce_interfaces, ce_observer,
  ce_synmemo, ce_writableComponent, ce_common, ce_sharedres, PropEdits,
  ObjectInspector;

type

  DfmtEol = (cr, lf, crlf);
  DfmtIndentstyle = (tab, space);
  DfmtBraceStyle = (allman, otbs, stroustrup);
  DfmtConstraint = (condNewLineIndent, condNewLine, alwaysNewLine, alwaysNewLineIndent);


type
  // wraps dfmt options to build the command line with ease
  // and allows to save the options between session.
  TCEDmtWrapper = class(TWritableLfmTextComponent)
  private
    fEol: DfmtEol;
    fTabStyle: DfmtIndentstyle;
    fIndentSize: integer;
    fTabWidth: integer;
    fHardLLen: integer;
    fSoftLLen: integer;
    fBraceStyle: DfmtBraceStyle;
    fSpaceCast: boolean;
    fSplitOp: boolean;
    fCompactLbl: boolean;
    fSpaceSelImp: boolean;
    fConstraints: DfmtConstraint;
    procedure setSoftLLen(value: integer);
    procedure setHardLLen(value: integer);
    procedure setTabWidth(value: integer);
    procedure setIndentSize(value: integer);
    procedure setEol(value: DfmtEol);
    procedure setBraceStyle(value: DfmtBraceStyle);
    procedure setIndentStyle(value: DfmtIndentstyle);
    procedure setConstraintsStyle(value: DfmtConstraint);
  published
    property endOfline: DfmtEol read fEol write setEol default lf;
    property indentationStyle: DfmtIndentstyle read fTabStyle write setIndentStyle default space;
    property indentSize: integer read fIndentSize write fIndentSize default 4;
    property tabWidth: integer read fTabWidth write fTabWidth default 4;
    property hardLineLen: integer read fHardLLen write fHardLLen default 120;
    property softLineLen: integer read fSoftLLen write fSoftLLen default 80;
    property braceStyle: DfmtBraceStyle read fBraceStyle write setBraceStyle default allman;
    property spaceAfterCast: boolean read fSpaceCast write fSpaceCast default true;
    property spaceAfterImport: boolean read fSpaceSelImp write fSpaceSelImp default true;
    property splitOpAtPrevLine: boolean read fSplitOp write fSplitOp default true;
    property compactLabeledStatements: boolean read fCompactLbl write fCompactLbl default true;
    property constraintsStyle: DfmtConstraint read fConstraints write setConstraintsStyle default condNewLineIndent;
  public
    constructor create(AOwner: TComponent); override;
    procedure getParameters(str: TStrings; majv, minv: Byte);
  end;

  { TCEDfmtWidget }

  TCEDfmtWidget = class(TCEWidget, ICEDocumentObserver, ICECodeFormatting)
    btnApply: TSpeedButton;
    btnCancel: TSpeedButton;
    pnlFooter: TPanel;
    dfmtOptionEditor: TTIPropertyGrid;
    procedure dfmtOptionEditorEditorFilter(Sender: TObject;
      aEditor: TPropertyEditor; var aShow: boolean);
  private
    fDoc: TCESynMemo;
    fBackup: TStringList;
    fDmtWrapper: TCEDmtWrapper;
    //
    procedure docNew(document: TCESynMemo);
    procedure docFocused(document: TCESynMemo);
    procedure docChanged(document: TCESynMemo);
    procedure docClosing(document: TCESynMemo);
    //
    procedure doApply(sender: TObject);
    procedure doCancel(sender: TObject);
  public
    constructor create(aOwner: TComponent); override;
    destructor destroy; override;
    function singleServiceName: string;
    procedure formatCurrent();
  end;

implementation
{$R *.lfm}

const
  optFname = 'dfmt.txt';

{$REGION Standard Comp/Obj------------------------------------------------------}
constructor TCEDfmtWidget.create(aOwner: TComponent);
var
  fname: string;
begin
  inherited;
  toolbarVisible:=false;
  fDmtWrapper := TCEDmtWrapper.Create(self);
  fBackup := TStringList.Create;

  fname := getCoeditDocPath + optFname;
  if fname.fileExists then
    fDmtWrapper.loadFromFile(fname);

  btnCancel.OnClick := @doCancel;
  btnApply.OnClick  := @doApply;
  case GetIconScaledSize of
    iss16:
    begin
      AssignPng(btnCancel, 'CANCEL');
      AssignPng(btnApply, 'ACCEPT');
    end;
    iss24:
    begin
      AssignPng(btnCancel, 'CANCEL24');
      AssignPng(btnApply, 'ACCEPT24');
    end;
    iss32:
    begin
      AssignPng(btnCancel, 'CANCEL32');
      AssignPng(btnApply, 'ACCEPT32');
    end;
  end;

  dfmtOptionEditor.TIObject := fDmtWrapper;
  dfmtOptionEditor.DefaultItemHeight:=scaleY(24,96);

  EntitiesConnector.addSingleService(self);
end;

destructor TCEDfmtWidget.destroy;
begin
  dfmtOptionEditor.TIObject := nil;
  fDmtWrapper.saveToFile(getCoeditDocPath + optFname);
  fBackup.Free;
  inherited;
end;

constructor TCEDmtWrapper.create(AOwner: TComponent);
begin
  inherited;
  fEol          := lf;
  fTabStyle     := DfmtIndentstyle.space;
  fIndentSize   := 4;
  fTabWidth     := 4;
  fHardLLen     := 120;
  fSoftLLen     := 80;
  fBraceStyle   := DfmtBraceStyle.allman;
  fSpaceCast    := true;
  fSpaceSelImp  := true;
  fSplitOp      := true;
  fCompactLbl   := true;
  fConstraints  := DfmtConstraint.condNewLineIndent;
end;

procedure TCEDfmtWidget.dfmtOptionEditorEditorFilter(Sender: TObject;
  aEditor: TPropertyEditor; var aShow: boolean);
begin
  case aEditor.GetName of
    'Tag', 'Name': aShow := false;
    else aShow := true;
  end;
end;

procedure TCEDmtWrapper.setSoftLLen(value: integer);
begin
  if value < 60 then
    value := 60
  else if value > 512 then
    value := 512;
  fSoftLLen := value;
end;

procedure TCEDmtWrapper.setHardLLen(value: integer);
begin
  if value < 60 then
    value := 60
  else if value > 512 then
    value := 512;
  fHardLLen := value;
end;

procedure TCEDmtWrapper.setTabWidth(value: integer);
begin
  if value < 1 then
    value := 1
  else if value > 8 then
    value := 8;
  fTabWidth := value;
end;

procedure TCEDmtWrapper.setIndentSize(value: integer);
begin
  if value < 1 then
    value := 1
  else if value > 8 then
    value := 8;
  fIndentSize := value;
end;

procedure TCEDmtWrapper.setEol(value: DfmtEol);
begin
  if not (value in [DfmtEol.cr, DfmtEol.lf, DfmtEol.crlf]) then
    value := DfmtEol.lf;
  fEol:=value;
end;

procedure TCEDmtWrapper.setBraceStyle(value: DfmtBraceStyle);
begin
  if not (value in [DfmtBraceStyle.allman, DfmtBraceStyle.otbs,
    DfmtBraceStyle.stroustrup]) then
      value := DfmtBraceStyle.allman;
  fBraceStyle:=value;
end;

procedure TCEDmtWrapper.setIndentStyle(value: DfmtIndentstyle);
begin
  if not (value in [DfmtIndentstyle.space, DfmtIndentstyle.tab]) then
    value := DfmtIndentstyle.space;
  fTabStyle:=value;
end;

procedure TCEDmtWrapper.setConstraintsStyle(value: DfmtConstraint);
begin
  if not (value in [DfmtConstraint.alwaysNewLine, DfmtConstraint.alwaysNewLineIndent,
    DfmtConstraint.condNewLine, DfmtConstraint.condNewLineIndent]) then
      value := DfmtConstraint.condNewLineIndent;
  fConstraints:=value;
end;
{$ENDREGION}

{$REGION ICEDocumentObserver ---------------------------------------------------}
procedure TCEDfmtWidget.docNew(document: TCESynMemo);
begin
  fDoc := document;
end;

procedure TCEDfmtWidget.docFocused(document: TCESynMemo);
begin
  if document = fDoc
    then exit;
  fDoc := document;
end;

procedure TCEDfmtWidget.docChanged(document: TCESynMemo);
begin
end;

procedure TCEDfmtWidget.docClosing(document: TCESynMemo);
begin
  if fDoc <> document then
    exit;
  fDoc := nil;
end;
{$ENDREGION}

{$REGION Dfmt things -----------------------------------------------------------}
procedure TCEDmtWrapper.getParameters(str: TStrings; majv, minv: Byte);
const
  eol: array[DfmtEol] of string = ('cr', 'lf', 'crlf');
  falsetrue: array[boolean] of string = ('false', 'true');
  idtstyle: array[DfmtIndentstyle] of string = ('tab', 'space');
  brc: array[DfmtBraceStyle] of string = ('allman', 'otbs', 'stroustrup');
  cts: array[DfmtConstraint] of string = ('conditional_newline_indent',
    'conditional_newline', 'always_newline', 'always_newline_indent');
begin
  str.Add('--end_of_line=' + eol[endOfline]);
  str.Add('--max_line_length=' + intToStr(hardLineLen));
  str.Add('--soft_max_line_length=' + intToStr(softLineLen));
  str.Add('--indent_size='  + intToStr(indentSize));
  str.Add('--indent_style=' + idtstyle[indentationStyle]);
  str.Add('--tab_width=' + intToStr(tabWidth));
  str.Add('--brace_style=' + brc[braceStyle]);
  str.Add('--split_operator_at_line_end=' + falsetrue[splitOpAtPrevLine]);
  str.Add('--space_after_cast=' + falsetrue[spaceAfterCast]);
  str.Add('--selective_import_space=' + falsetrue[spaceAfterImport]);
  str.Add('--compact_labeled_statements=' + falsetrue[compactLabeledStatements]);
  if (majv = 0) and (minv > 4) then
    str.Add('--template_constraint_style=' + cts[fConstraints]);
end;

function TCEDfmtWidget.singleServiceName: string;
begin
  exit('ICECodeFormatting');
end;

procedure TCEDfmtWidget.formatCurrent();
begin
  doApply(self);
end;

procedure TCEDfmtWidget.doApply(sender: TObject);
var
  inp: string;
  i: integer;
  prc: TProcess;
  str: TStringList;
  majv: byte = 0;
  minv: byte = 4;
begin
  if fDoc.isNil then
    exit;
  if not exeInSysPath('dfmt') then
    exit;

  //fBackup.Assign(fDoc.Lines);
  //prc := TProcess.create(nil);
  //try
  //  prc.Executable:= exeFullName('dfmt' + exeExt);
  //  prc.Options:= prc.Options + [poUsePipes, poStderrToOutPut];
  //
  //  setLength(inp, 20);
  //  prc.Parameters.Add('--version');
  //  prc.Execute;
  //  i := prc.Output.Read(inp[1], 20);
  //  if (i > 4) and (inp[2] = '.') then
  //  begin
  //    majv := Byte(inp[1]) - Byte('0');
  //    minv := Byte(inp[3]) - Byte('0');
  //  end;
  //  while prc.Running do
  //    sleep(1);
  //
  //  prc.Parameters.Clear;
  //  fDmtWrapper.getParameters(prc.Parameters, majv, minv);
  //  prc.Execute;
  //  inp := fDoc.Lines.Text;
  //  prc.Input.Write(inp[1], inp.length);
  //  prc.CloseInput;
  //  try
  //    str := TStringList.Create;
  //    processOutputToStrings(prc,str);
  //    fDoc.replaceUndoableContent(str.strictText);
  //  except
  //    fDoc.Lines.Assign(fBackup);
  //  end;
  //  while prc.Running do
  //    sleep(1);
  //finally
  //  prc.free;
  //  str.free;
  //end;
end;

procedure TCEDfmtWidget.doCancel(sender: TObject);
begin
  //if fDoc.isNil then
  //  exit;
  //fDoc.Lines.Assign(fBackup);
end;
{$ENDREGION}

end.

