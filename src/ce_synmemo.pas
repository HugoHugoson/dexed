unit ce_synmemo;

{$I ce_defines.inc}

interface

uses
  Classes, SysUtils, controls,lcltype, Forms, graphics, ExtCtrls, crc, process,
  SynEdit, SynPluginSyncroEdit, SynCompletion, SynEditKeyCmds, LazSynEditText,
  SynHighlighterLFM, SynEditHighlighter, SynEditMouseCmds, SynEditFoldedView,
  SynEditMarks, SynEditTypes, SynHighlighterJScript, SynBeautifier, dialogs, math,
  md5, ATSynEdit, ATSynEdit_Carets, ATStrings, ATStringProc, ATSynEdit_Commands,
  //SynEditMarkupFoldColoring,
  Clipbrd, fpjson, jsonparser, LazUTF8, LazUTF8Classes, Buttons, StdCtrls,
  ce_common, ce_writableComponent, ce_d2syn, ce_txtsyn, ce_dialogs, ce_dastworx,
  ce_sharedres, ce_dlang, ce_stringrange, ce_dbgitf, ce_observer, ce_diff,
  ce_processes;

type

  TCESynMemo = class;

  TIdentifierMatchOption = (
    caseSensitive = longInt(ssoMatchCase),
    wholeWord = longInt(ssoWholeWord)
  );

  TBraceAutoCloseStyle = (
    autoCloseNever,
    autoCloseAtEof,
    autoCloseAlways,
    autoCloseLexically,
    autoCloseOnNewLineEof,
    autoCloseOnNewLineAlways,
    autoCloseOnNewLineLexically
  );

  TAutoClosedPair = (
    autoCloseSingleQuote,
    autoCloseDoubleQuote,
    autoCloseBackTick,
    autoCloseSquareBracket
  );

  TAutoClosePairs = set of TAutoClosedPair;

const

  autoClosePair2Char: array[TAutoClosedPair] of char = (#39, '"', '`', ']');

type

  TIdentifierMatchOptions = set of TIdentifierMatchOption;

  // Simple THintWindow descendant allowing the font size to be in sync with the editor.
  TCEEditorHintWindow = class(THintWindow)
  public
    class var FontSize: Integer;
    function CalcHintRect(MaxWidth: Integer; const AHint: string;
      AData: Pointer): TRect; override;
  end;

  // Stores the state of a particular source code folding.
  TCEFoldCache = class(TCollectionItem)
  private
    fCollapsed: boolean;
    fLineIndex: Integer;
    fNestedIndex: Integer;
  published
    property isCollapsed: boolean read fCollapsed   write fCollapsed;
    property lineIndex: Integer   read fLineIndex   write fLineIndex;
    property nestedIndex: Integer read fNestedIndex write fNestedIndex;
  end;

  // Stores the state of a document between two cessions.
  TCESynMemoCache = class(TWritableLfmTextComponent)
  private
    fMemo: TCESynMemo;
    fFolds: TCollection;
    fCaretPosition: Integer;
    fSelectionEnd: Integer;
    fFontSize: Integer;
    fSourceFilename: string;
    procedure setFolds(someFolds: TCollection);
  published
    property caretPosition: Integer read fCaretPosition write fCaretPosition;
    property sourceFilename: string read fSourceFilename write fSourceFilename;
    property folds: TCollection read fFolds write setFolds;
    property selectionEnd: Integer read fSelectionEnd write fSelectionEnd;
    property fontSize: Integer read fFontSize write fFontSize;
  public
    constructor create(aComponent: TComponent); override;
    destructor destroy; override;
    procedure beforeSave; override;
    procedure afterLoad; override;
    procedure save;
    procedure load;
  end;

  // Caret positions buffer allowing to jump fast to the most recent locations.
  // Replaces the bookmarks.
  TCESynMemoPositions = class
  private
    fPos: Integer;
    fMax: Integer;
    fList: TFPList;
    fMemo: TCESynMemo;
  public
    constructor create(memo: TCESynMemo);
    destructor destroy; override;
    procedure store;
    procedure back;
    procedure next;
  end;

  PDscannerResult = ^TDscannerResult;
  TDscannerResult = record
    warning: string;
    line, column: integer;
  end;

  TDscannerResults = class
  private
    fList: TFPList;
    function getItem(index: integer): PDscannerResult;
    function getCount: integer;
  public
    constructor create;
    destructor destroy; override;
    procedure clear;
    procedure push(const warning: string; line, column: integer);
    property count: integer read getCount;
    property item[index: integer]: PDscannerResult read getItem; default;
  end;

  TSortDialog = class;

  TGutterIcon = (
    giBreakSet    = 0,          // breakpoint set here
    giBulletGreen = 1,
    giBulletBlack = 2,
    giBreakReached= 3,          // break point reached
    giStep        = 4,          // step / signal / pause
    giWatch       = 5,          // watch point reached
    giWarn        = 6           // Dscanner result with text hint
  );

  const debugTimeGutterIcons = [giBreakReached, giStep, giWatch];

type

  //TODO-cGDB: add a system allowing to define watch points

  // Partial read-only editor displayed as scroll hint
  TCEScrollMemo = class(TPanel)
  private
    fMemo: TSynEdit;
    fD2Hl: TSynD2Syn;
    fTxtHl: TSynTxtSyn;
    fSource: TCESynMemo;
    procedure updateFromSource;
  protected
    procedure SetVisible(Value: Boolean); override;
  public
    constructor construct(editor: TCESynMemo);
    procedure goToLine(value: integer);
  end;

  TCESynMemo = class(TATSynEdit, ICEDebugObserver)
  private
    //fIndentGuideMarkup: TSynEditMarkupFoldColors;
    fScrollMemo: TCEScrollMemo;
    fFilename: string;
    fDastWorxExename: string;
    fFileDate: double;
    fCacheLoaded: boolean;
    fIsDSource: boolean;
    fIsTxtFile: boolean;
    fFocusForInput: boolean;
    fIdentifier: string;
    fTempFileName: string;
    fMultiDocSubject: TObject;
    fDefaultFontSize: Integer;
    fPositions: TCESynMemoPositions;
    fMousePos: TPoint;
    fCallTipWin: TCEEditorHintWindow;
    fDDocWin: TCEEditorHintWindow;
    fDDocDelay: Integer;
    fAutoDotDelay: Integer;
    fDscannerDelay: Integer;
    fDDocTimer: TIdleTimer;
    fAutoDotTimer: TIdleTimer;
    fDscannerTimer: TIdleTimer;
    fCanShowHint: boolean;
    fCanAutoDot: boolean;
    fOldMousePos: TPoint;
    fSyncEdit: TSynPluginSyncroEdit;
    fCompletion: TSynCompletion;
    fD2Highlighter: TSynD2Syn;
    fTxtHighlighter: TSynTxtSyn;
    fImages: TImageList;
    fMatchSelectionOpts: TSynSearchOptions;
    fMatchIdentOpts: TSynSearchOptions;
    fMatchOpts: TIdentifierMatchOptions;
    fCallTipStrings: TStringList;
    fOverrideColMode: boolean;
    fAutoCloseCurlyBrace: TBraceAutoCloseStyle;
    fSmartDdocNewline: boolean;
    fLexToks: TLexTokenList;
    fDisableFileDateCheck: boolean;
    fDetectIndentMode: boolean;
    fPhobosDocRoot: string;
    fAlwaysAdvancedFeatures: boolean;
    fIsProjectDescription: boolean;
    fAutoClosedPairs: TAutoClosePairs;
    fSortDialog: TSortDialog;
    fModuleTokFound: boolean;
    fHasModuleDeclaration: boolean;
    fLastCompletion: string;
    fDebugger: ICEDebugger;
    fInsertPlusDdoc: boolean;
    fAutoCallCompletion: boolean;
    fCloseCompletionCharsWithSpace: TSysCharSet;
    fCloseCompletionChars: TSysCharSet;
    fCompletionMenuAutoClose: boolean;
    fTransparentGutter: boolean;
    fDscanner: TCEProcess;
    fDscannerResults: TDscannerResults;
    fCanDscan: boolean;
    fKnowsDscanner: boolean;
    fDscannerEnabled: boolean;
    fScrollPreview: boolean;
    fDiffDialogWillClose: boolean;
    procedure showHintEvent(Sender: TObject; HintInfo: PHintInfo);
    procedure setGutterTransparent(value: boolean);
    procedure decCallTipsLvl;
    procedure setMatchOpts(value: TIdentifierMatchOptions);
    function getMouseBytePosition: integer;
    function getCaretBytePosition: integer;
    procedure setCaretBytePosition(value: integer);
    procedure changeNotify(Sender: TObject);
    procedure highlightCurrentIdentifier;
    procedure saveCache;
    procedure loadCache;
    class procedure cleanCache; static;
    procedure setDefaultFontSize(value: Integer);
    procedure DDocTimerEvent(sender: TObject);
    procedure AutoDotTimerEvent(sender: TObject);
    procedure dscannerTimerEvent(sender: TObject);
    procedure dscannerTerminate(sender: TObject);
    procedure removeDscannerWarnings;
    function getDscannerWarning(line: integer): string;
    function lineHasDscannerWarning(line: integer): boolean;
    procedure InitHintWins;
    function getIfTemp: boolean;
    procedure setDDocDelay(value: Integer);
    procedure setAutoDotDelay(value: Integer);
    procedure completionExecute(sender: TObject);
    procedure completionDeleteKey(sender: TObject);
    procedure getCompletionList;
    procedure completionFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    function completionItemPaint(const AKey: string; ACanvas: TCanvas;X, Y: integer;
      Selected: boolean; Index: integer): boolean;
    procedure completionCodeCompletion(var value: string; SourceValue: string;
      var SourceStart, SourceEnd: TPoint; KeyChar: TUTF8Char; Shift: TShiftState);
    procedure showCallTips(const tips: string);
    function lexCanCloseBrace: boolean;
    function lexInDdoc: char;
    procedure handleStatusChanged(Sender: TObject; Changes: TSynStatusChanges);
    procedure goToChangedArea(next: boolean);
    procedure goToProtectionGroup(next: boolean);
    procedure goToWarning(next: boolean);
    procedure autoClosePair(value: TAutoClosedPair);
    procedure setSelectionOrWordCase(upper: boolean);
    procedure sortSelectedLines(descending, caseSensitive: boolean);
    procedure tokFoundForCaption(const token: PLexToken; out stop: boolean);
    procedure addGutterIcon(line: integer; value: TGutterIcon);
    procedure removeGutterIcon(line: integer; value: TGutterIcon);
    procedure patchClipboardIndentation;
    function getCaretX: integer;
    function getCaretY: integer;
    function getCaretXY: TPoint;
    function getNormalizedSelRect: TRect;
    procedure setCaretX(value: integer);
    procedure setCaretY(value: integer);
    procedure setCaretXY(value: TPoint);
    //
    procedure gutterClick(Sender: TObject; X, Y, Line: integer; mark: TSynEditMark);
    procedure removeDebugTimeMarks;
    function  isGutterIconSet(line: integer; value: TGutterIcon): boolean;
    function  findBreakPoint(line: integer): boolean;
    procedure debugStart(debugger: ICEDebugger);
    procedure debugStop;
    procedure debugContinue;
    function debugQueryBpCount: integer;
    procedure debugQueryBreakPoint(const line: integer; out fname: string; out kind: TBreakPointKind);
    procedure debugBreak(const fname: string; line: integer; reason: TCEDebugBreakReason);
    function breakPointsCount: integer;
  protected
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure MouseLeave; override;
    procedure SetVisible(Value: Boolean); override;
    procedure SetHighlighter(const Value: TSynCustomHighlighter); {override;}
    procedure UTF8KeyPress(var Key: TUTF8Char); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; Shift: TShiftState); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y:Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y:Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(aOwner: TComponent); override;
    destructor destroy; override;
    procedure setFocus; override;
    procedure showPage;
    //
    function pageCaption(checkModule: boolean): string;
    procedure checkFileDate;
    procedure loadFromFile(const fname: string); override;
    procedure saveToFile(const fname: string); override;
    procedure save;
    procedure saveTempFile;
    //
    procedure DoCommand(ACmd: integer; const AText: atString = ''); override;
    function hasSelection: boolean;
    function selTextUTF8: string;
    function lineTextAtCarret: string;
    function indentationMode: TIndentationMode;
    procedure selectLineAtCaret();
    procedure addBreakPoint(line: integer);
    procedure removeBreakPoint(line: integer);
    procedure curlyBraceCloseAndIndent;
    procedure insertLeadingDDocSymbol(c: char);
    procedure commentSelection;
    procedure commentIdentifier;
    procedure renameIdentifier;
    procedure invertVersionAllNone;
    procedure showCallTips(findOpenParen: boolean = true);
    procedure hideCallTips;
    procedure showDDocs;
    procedure hideDDocs;
    procedure ShowPhobosDoc;
    procedure previousChangedArea;
    procedure nextChangedArea;
    procedure previousProtectionGroup;
    procedure nextProtectionGroup;
    procedure previousWarning;
    procedure nextWarning;
    procedure sortLines;
    procedure addCurLineBreakPoint;
    procedure removeCurLineBreakPoint;
    procedure toggleCurLineBreakpoint;
    procedure insertDdocTemplate;
    procedure gotoLinePrompt;
    procedure showWarningForLine(line: integer);
    procedure showCurLineWarning;
    function implementMain: THasMain;
    procedure replaceUndoableContent(const value: string);
    procedure setDscannerOptions(dsEnabled: boolean; dsDelay: integer);
    //
    property IdentifierMatchOptions: TIdentifierMatchOptions read fMatchOpts write setMatchOpts;
    property Identifier: string read fIdentifier;
    property fileName: string read fFilename;
    property modified;
    property tempFilename: string read fTempFileName;
    //
    property completionMenu: TSynCompletion read fCompletion;
    property syncroEdit: TSynPluginSyncroEdit read fSyncEdit;
    property isDSource: boolean read fIsDSource;
    property isTemporary: boolean read getIfTemp;
    //property TextView;
    //
    property normalizedSelRect: TRect read getNormalizedSelRect;
    property caretX: integer read getCaretX write setCaretX;
    property caretY: integer read getCaretY write setCaretY;
    property caretXY: TPoint read getCaretXY write setCaretXY;
    property transparentGutter: boolean read fTransparentGutter write setGutterTransparent;
    property isProjectDescription: boolean read fIsProjectDescription write fIsProjectDescription;
    property alwaysAdvancedFeatures: boolean read fAlwaysAdvancedFeatures write fAlwaysAdvancedFeatures;
    property phobosDocRoot: string read fPhobosDocRoot write fPhobosDocRoot;
    property detectIndentMode: boolean read fDetectIndentMode write fDetectIndentMode;
    property disableFileDateCheck: boolean read fDisableFileDateCheck write fDisableFileDateCheck;
    property mouseBytePosition: Integer read getMouseBytePosition;
    property caretBytePosition: Integer read getCaretBytePosition write setCaretBytePosition;
    property D2Highlighter: TSynD2Syn read fD2Highlighter;
    property TxtHighlighter: TSynTxtSyn read fTxtHighlighter;
    property defaultFontSize: Integer read fDefaultFontSize write setDefaultFontSize;
    property ddocDelay: Integer read fDDocDelay write setDDocDelay;
    property autoDotDelay: Integer read fAutoDotDelay write setAutoDotDelay;
    property autoCloseCurlyBrace: TBraceAutoCloseStyle read fAutoCloseCurlyBrace write fAutoCloseCurlyBrace;
    property autoClosedPairs: TAutoClosePairs read fAutoClosedPairs write fAutoClosedPairs;
    property smartDdocNewline: boolean read fSmartDdocNewline write fSmartDdocNewline;
    property insertPlusDdoc: boolean read fInsertPlusDdoc write fInsertPlusDdoc;
    property autoCallCompletion: boolean read fAutoCallCompletion write fAutoCallCompletion;
    property closeCompletionCharsWithSpace: TSysCharSet read fCloseCompletionCharsWithSpace write fCloseCompletionCharsWithSpace;
    property closeCompletionChars: TSysCharSet read fCloseCompletionChars write fCloseCompletionChars;
    property completionMenuAutoClose: boolean read fCompletionMenuAutoClose write fCompletionMenuAutoClose;
    property scrollPreview: boolean read fScrollPreview write fScrollPreview;
  end;

  TSortDialog = class(TForm)
  private
    class var fDescending: boolean;
    class var fCaseSensitive: boolean;
    fEditor: TCESynMemo;
    fCanUndo: boolean;
    procedure btnApplyClick(sender: TObject);
    procedure btnUndoClick(sender: TObject);
    procedure chkCaseSensClick(sender: TObject);
    procedure chkDescClick(sender: TObject);
  public
    constructor construct(editor: TCESynMemo);
  end;

  procedure SetDefaultCoeditKeystrokes(ed: TSynEdit);

  function CustomStringToCommand(const Ident: string; var Int: Longint): Boolean;
  function CustomCommandToSstring(Int: Longint; var Ident: string): Boolean;

const
  ecCompletionMenu      = cCommand_FirstUser + 1;
  ecJumpToDeclaration   = cCommand_FirstUser + 2;
  ecPreviousLocation    = cCommand_FirstUser + 3;
  ecNextLocation        = cCommand_FirstUser + 4;
  ecRecordMacro         = cCommand_FirstUser + 5;
  ecPlayMacro           = cCommand_FirstUser + 6;
  ecShowDdoc            = cCommand_FirstUser + 7;
  ecShowCallTips        = cCommand_FirstUser + 8;
  ecCurlyBraceClose     = cCommand_FirstUser + 9;
  ecCommentSelection    = cCommand_FirstUser + 10;
  ecSwapVersionAllNone  = cCommand_FirstUser + 11;
  ecRenameIdentifier    = cCommand_FirstUser + 12;
  ecCommentIdentifier   = cCommand_FirstUser + 13;
  ecShowPhobosDoc       = cCommand_FirstUser + 14;
  ecPreviousChangedArea = cCommand_FirstUser + 15;
  ecNextChangedArea     = cCommand_FirstUser + 16;
  ecUpperCaseWordOrSel  = cCommand_FirstUser + 17;
  ecLowerCaseWordOrSel  = cCommand_FirstUser + 18;
  ecSortLines           = cCommand_FirstUser + 19;
  ecPrevProtGrp         = cCommand_FirstUser + 20;
  ecNextProtGrp         = cCommand_FirstUser + 21;
  ecAddBreakpoint       = cCommand_FirstUser + 22;
  ecRemoveBreakpoint    = cCommand_FirstUser + 23;
  ecToggleBreakpoint    = cCommand_FirstUser + 24;
  ecInsertDdocTemplate  = cCommand_FirstUser + 25;
  ecNextWarning         = cCommand_FirstUser + 26;
  ecPrevWarning         = cCommand_FirstUser + 27;
  ecGotoLine            = cCommand_FirstUser + 28;
  ecShowCurlineWarning  = cCommand_FirstUser + 29;

var
  D2Syn: TSynD2Syn;     // used as model to set the options when no editor exists.
  TxtSyn: TSynTxtSyn;   // used as model to set the options when no editor exists.
  LfmSyn: TSynLfmSyn;   // used to highlight the native projects.
  JsSyn: TSynJScriptSyn;// used to highlight the DUB JSON projects.


implementation

uses
  ce_interfaces, ce_dcd, ce_staticmacro, SynEditHighlighterFoldBase, ce_lcldragdrop;

const
  DcdCompletionKindStrings: array[TDCDCompletionKind] of string = (
    ' (class)            ',
    ' (interface)        ',
    ' (struct)           ',
    ' (union)            ',
    ' (variable)         ',
    ' (member)           ',
    ' (reserved word)    ',
    ' (function)         ',
    ' (enum)             ',
    ' (enum member)      ',
    ' (package)          ',
    ' (module)           ',
    ' (array)            ',
    ' (associative array)',
    ' (alias)            ',
    ' (template)         ',
    ' (mixin)            '
  );

function TCEEditorHintWindow.CalcHintRect(MaxWidth: Integer; const AHint: String; AData: Pointer): TRect;
begin
  Font.Size:= FontSize;
  result := inherited CalcHintRect(MaxWidth, AHint, AData);
end;

{$REGION TSortDialog -----------------------------------------------------------}
constructor TSortDialog.construct(editor: TCESynMemo);
var
  pnl: TPanel;
begin
  inherited Create(nil);
  fEditor := editor;

  width := 150;
  Height:= 95;
  FormStyle:= fsStayOnTop;
  BorderStyle:= bsToolWindow;
  Position:= poScreenCenter;
  ShowHint:=true;

  with TCheckBox.Create(self) do
  begin
    parent := self;
    BorderSpacing.Around:=2;
    OnClick:=@chkCaseSensClick;
    Caption:='case sensitive';
    checked := fCaseSensitive;
    align := alTop;
  end;

  with TCheckBox.Create(self) do
  begin
    parent := self;
    BorderSpacing.Around:=2;
    OnClick:=@chkDescClick;
    Caption:='descending';
    Checked:= fDescending;
    align := alTop;
  end;

  pnl := TPanel.Create(self);
  pnl.Parent := self;
  pnl.Align:=alBottom;
  pnl.Caption:='';
  pnl.Height:= 32;
  pnl.BevelOuter:=bvLowered;

  with TSpeedButton.Create(self) do
  begin
    parent := pnl;
    BorderSpacing.Around:=2;
    OnClick:=@btnUndoClick;
    align := alRight;
    width := 28;
    Hint := 'undo changes';
    AssignPng(Glyph, 'ARROW_UNDO');
  end;

  with TSpeedButton.Create(self) do
  begin
    parent := pnl;
    BorderSpacing.Around:=2;
    OnClick:=@btnApplyClick;
    align := alRight;
    width := 28;
    Hint := 'apply sorting';
    AssignPng(Glyph, 'ACCEPT');
  end;
end;

procedure TSortDialog.btnApplyClick(sender: TObject);
begin
  fEditor.sortSelectedLines(fDescending, fCaseSensitive);
  fCanUndo:= true;
end;

procedure TSortDialog.btnUndoClick(sender: TObject);
begin
  //if fCanUndo then
  //  fEditor.undo;
  fCanUndo:= false;
end;

procedure TSortDialog.chkCaseSensClick(sender: TObject);
begin
  fCaseSensitive := TCheckBox(sender).checked;
end;

procedure TSortDialog.chkDescClick(sender: TObject);
begin
  fDescending := TCheckBox(sender).checked;
end;
{$ENDREGION}

{$REGION TCESynMemoCache -------------------------------------------------------}
constructor TCESynMemoCache.create(aComponent: TComponent);
begin
  inherited create(nil);
  if (aComponent is TCESynMemo) then
  	fMemo := TCESynMemo(aComponent);
  fFolds := TCollection.Create(TCEFoldCache);
end;

destructor TCESynMemoCache.destroy;
begin
  fFolds.Free;
  inherited;
end;

procedure TCESynMemoCache.setFolds(someFolds: TCollection);
begin
  fFolds.Assign(someFolds);
end;

procedure TCESynMemoCache.beforeSave;
var
  i, start, prev: Integer;
  itm : TCEFoldCache;
begin
  if fMemo.isNil then
    exit;
  //
  fCaretPosition := fMemo.caretBytePosition;
  fSourceFilename := fMemo.fileName;
  //fSelectionEnd := fMemo.SelEnd;
  fFontSize := fMemo.Font.Size;
  TCEEditorHintWindow.FontSize := fMemo.Font.Size;
  //
  //prev := fMemo.Lines.Count-1;
  //for i := fMemo.Lines.Count-1 downto 0 do
  //begin
  //  // - CollapsedLineForFoldAtLine() does not handle the sub-folding.
  //  // - TextView visibility is increased so this is not the standard way of getting the infos.
  //  start := fMemo.TextView.CollapsedLineForFoldAtLine(i);
  //  if start = -1 then
  //    continue;
  //  if start = prev then
  //    continue;
  //  prev := start;
  //  itm := TCEFoldCache(fFolds.Add);
  //  itm.isCollapsed := true;
  //  itm.fLineIndex := start;
  //end;
end;

procedure TCESynMemoCache.afterLoad;
var
  i: integer;
  itm : TCEFoldCache;
begin
  if fMemo.isNil then
    exit;
  //
  if fFontSize > 0 then
    fMemo.Font.Size := fFontSize;
  //
  // Currently collisions are not handled.
  if fMemo.fileName <> fSourceFilename then
    exit;
  //
  //for i := 0 to fFolds.Count-1 do
  //begin
  //  itm := TCEFoldCache(fFolds.Items[i]);
  //  if not itm.isCollapsed then
  //    continue;
  //  fMemo.TextView.FoldAtLine(itm.lineIndex-1);
  //end;
  //
  fMemo.caretBytePosition := fCaretPosition;
  //fMemo.SelEnd := fSelectionEnd;
end;

{$IFDEF DEBUG}{$R-}{$ENDIF}
procedure TCESynMemoCache.save;
var
  fname: string;
  tempn: string;
  chksm: Cardinal;
begin
  tempn := fMemo.fileName;
  if (tempn = fMemo.tempFilename) or (not tempn.fileExists) then
    exit;

  fname := getCoeditDocPath + 'editorcache' + DirectorySeparator;
  ForceDirectories(fname);
  chksm := crc32(0, nil, 0);
  chksm := crc32(chksm, @tempn[1], tempn.length);
  fname := fname + format('%.8X.txt', [chksm]);
  saveToFile(fname);
end;

procedure TCESynMemoCache.load;
var
  fname: string;
  tempn: string;
  chksm: Cardinal;
begin
  tempn := fMemo.fileName;
  if not tempn.fileExists then
    exit;

  fname := getCoeditDocPath + 'editorcache' + DirectorySeparator;
  chksm := crc32(0, nil, 0);
  chksm := crc32(chksm, @tempn[1], tempn.length);
  fname := fname + format('%.8X.txt', [chksm]);

  if not fname.fileExists then
    exit;
  loadFromFile(fname);
end;
{$IFDEF DEBUG}{$R+}{$ENDIF}
{$ENDREGION}

{$REGION TCESynMemoPositions ---------------------------------------------------}
constructor TCESynMemoPositions.create(memo: TCESynMemo);
begin
  fList := TFPList.Create;
  fMax  := 40;
  fMemo := memo;
  fPos  := -1;
end;

destructor TCESynMemoPositions.destroy;
begin
  fList.Free;
  inherited;
end;

procedure TCESynMemoPositions.back;
begin
  Inc(fPos);
  {$HINTS OFF}
  if fPos < fList.Count then
    fMemo.caretY := NativeInt(fList.Items[fPos])
  {$HINTS ON}
  else Dec(fPos);
end;

procedure TCESynMemoPositions.next;
begin
  Dec(fPos);
  {$HINTS OFF}
  if fPos > -1 then
    fMemo.caretY := NativeInt(fList.Items[fPos])
  {$HINTS ON}
  else Inc(fPos);
end;

procedure TCESynMemoPositions.store;
var
  delta: NativeInt;
const
  thresh = 6;
begin
  fPos := 0;
  {$PUSH}
  {$HINTS OFF}{$WARNINGS OFF}
  if fList.Count > 0 then
  begin
    delta := fMemo.caretY - NativeInt(fList.Items[fPos]);
    if (delta > -thresh) and (delta < thresh) then exit;
  end;
  fList.Insert(0, Pointer(NativeInt(fMemo.caretY)));
  {$POP}
  while fList.Count > fMax do
    fList.Delete(fList.Count-1);
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION TCEScrollMemo ---------------------------------------------------------}
constructor TCEScrollMemo.construct(editor: TCESynMemo);
begin
  inherited create(editor);
  visible := false;

  parent := editor;
  width := 475;
  height := 275;

  fMemo:= TSynEdit.Create(self);
  fMemo.Parent := self;
  fMemo.Align:= alCLient;
  fMemo.ReadOnly:=true;
  fMemo.ScrollBars:=ssNone;
  fMemo.MouseActions.Clear;
  fMemo.Keystrokes.Clear;
  fMemo.CaptureMouseButtons:=[];
  fMemo.Options:=fMemo.Options+[eoNoCaret];

  fD2Hl:= TSynD2Syn.create(self);
  fTxtHl:= TSynTxtSyn.Create(self);
  fSource:= editor;
  updateFromSource();
end;

procedure TCEScrollMemo.updateFromSource;
begin
  //fMemo.Font.Assign(fSource.Font);
  //fMemo.Lines := fSource.Lines;
  //width := fSource.Width div 2;
  //if fSource.Highlighter.isNotNil then
  //begin
  //  fMemo.Color:= fSource.Color;
  //  fMemo.LineHighlightColor.Assign(fSource.LineHighlightColor);
  //  fMemo.SelectedColor.Assign(fSource.SelectedColor);
  //  if fMemo.Highlighter.isNil then
  //  begin
  //    fD2Hl.Assign(fSource.Highlighter);
  //    fTxtHl.Assign(fSource.Highlighter);
  //  end;
  //  if fSource.Highlighter is TSynD2Syn then
  //    fMemo.Highlighter := fD2Hl
  //  else
  //    fMemo.Highlighter := fTxtHl;
  //end;
end;

procedure TCEScrollMemo.SetVisible(Value: Boolean);
var
  o: boolean;
begin
  o := Visible;
  inherited;
  if (o <> value) and value then
    updateFromSource;
end;

procedure TCEScrollMemo.goToLine(value: integer);
begin
  if fMemo.PaintLock <> 0 then
    exit;
  if value > fMemo.Lines.Count then
    value := fMemo.Lines.Count
  else if value < 1 then
    value := 1;
  fMemo.CaretY := value;
  fMemo.CaretX := 1;
  fMemo.SelectLine();
end;
{$ENDREGION}

{$REGION TCESynMemo ------------------------------------------------------------}

{$REGION Standard Obj and Comp -------------------------------------------------}
constructor TCESynMemo.Create(aOwner: TComponent);
var
  z: TIconScaledSize;
begin
  inherited;

  fScrollMemo := TCEScrollMemo.construct(self);

  OnShowHint:= @showHintEvent;
  //OnStatusChange:= @handleStatusChanged;
  fDefaultFontSize := 10;
  Font.Size:=10;
  //SetDefaultCoeditKeystrokes(Self); // not called in inherited if owner = nil !
  fLexToks:= TLexTokenList.Create;
  fSmartDdocNewline := true;

  OnDragDrop:= @ddHandler.DragDrop;
  OnDragOver:= @ddHandler.DragOver;

  ShowHint := false;
  InitHintWins;
  fDDocDelay := 200;
  fDDocTimer := TIdleTimer.Create(self);
  fDDocTimer.AutoEnabled:=true;
  fDDocTimer.Interval := fDDocDelay;
  fDDocTimer.OnTimer := @DDocTimerEvent;

  fAutoDotDelay := 20;
  fAutoDotTimer := TIdleTimer.Create(self);
  fAutoDotTimer.AutoEnabled:=true;
  fAutoDotTimer.Interval := fAutoDotDelay;
  fAutoDotTimer.OnTimer := @AutoDotTimerEvent;

  fDscannerDelay := 500;
  fDscannerTimer := TIdleTimer.Create(self);
  fDscannerTimer.AutoEnabled:=true;
  fDscannerTimer.Interval := fDscannerDelay;
  fDscannerTimer.OnTimer := @dscannerTimerEvent;
  fDscanner := TCEProcess.create(self);
  fDscanner.Executable:= exeFullName('dscanner' + exeExt);
  fDscanner.Options:=[poUsePipes];
  fDscanner.ShowWindow:=swoHIDE;
  fDscanner.OnTerminate:=@dscannerTerminate;
  fDscanner.Parameters.add('-S');
  fDscanner.Parameters.add('stdin');
  fDscannerResults:= TDscannerResults.create;
  fKnowsDscanner := fDscanner.Executable.fileExists;

  //Gutter.LineNumberPart.ShowOnlyLineNumbersMultiplesOf := 5;
  //Gutter.LineNumberPart.MarkupInfo.Foreground := clWindowText;
  //Gutter.LineNumberPart.MarkupInfo.Background := clBtnFace;
  //Gutter.SeparatorPart.LineOffset := 0;
  //Gutter.SeparatorPart.LineWidth := 1;
  //Gutter.OnGutterClick:= @gutterClick;
  //BracketMatchColor.Foreground:=clRed;

  fSyncEdit := TSynPluginSyncroEdit.Create(self);
  //fSyncEdit.Editor := self;
  fSyncEdit.CaseSensitive := true;

  fCompletion := TSyncompletion.create(nil);
  fCompletion.ShowSizeDrag := true;
  //fCompletion.Editor := Self;
  fCompletion.OnExecute:= @completionExecute;
  fCompletion.OnCodeCompletion:=@completionCodeCompletion;
  fCompletion.OnPaintItem:= @completionItemPaint;
  fCompletion.OnKeyDelete:= @completionDeleteKey;
  fCompletion.TheForm.OnKeyDown:= @completionFormKeyDown;
  fCompletion.CaseSensitive:=true;
  TStringList(fCompletion.ItemList).CaseSensitive:=true;
  fCompletion.LongLineHintType:=sclpNone;
  fCompletion.TheForm.ShowInTaskBar:=stNever;
  fCompletion.ShortCut:=0;
  fCompletion.LinesInWindow:=15;
  fCompletion.Width:= 250;
  fCallTipStrings:= TStringList.Create;

  //MouseLinkColor.Style:= [fsUnderline];
  //with MouseActions.Add do begin
  //  Command := emcMouseLink;
  //  shift := [ssCtrl];
  //  ShiftMask := [ssCtrl];
  //end;

  fD2Highlighter := TSynD2Syn.create(self);
  fTxtHighlighter := TSynTxtSyn.Create(self);
  //Highlighter := fD2Highlighter;

  fTempFileName := GetTempDir(false) + 'temp_' + uniqueObjStr(self) + '.d';
  fFilename := '<new document>';
  Modified := false;
  self.OnChange := @changeNotify;
  self.OnChangeCaretPos := @changeNotify;
  //TextBuffer.AddNotifyHandler(senrUndoRedoAdded, @changeNotify);

  //Gutter.MarksPart.AutoSize:=false;
  //Gutter.MarksPart.Width := ScaleX(20,96);
  fImages := TImageList.Create(self);
  z := GetIconScaledSize;
  case z of
    iss16:
    begin
      fImages.Width:= 16;
      fImages.Height:= 16;
      fImages.AddResourceName(HINSTANCE, 'BREAK_SET');
      fImages.AddResourceName(HINSTANCE, 'BULLET_GREEN');
      fImages.AddResourceName(HINSTANCE, 'BULLET_BLACK');
      fImages.AddResourceName(HINSTANCE, 'BREAK_REACHED');
      fImages.AddResourceName(HINSTANCE, 'STEP');
      fImages.AddResourceName(HINSTANCE, 'CAMERA_GO');
      fImages.AddResourceName(HINSTANCE, 'WARNING');
      AssignPng(fSyncEdit.GutterGlyph, 'LINK_EDIT');
    end;
    iss24:
    begin
      fImages.Width:= 24;
      fImages.Height:= 24;
      fImages.AddResourceName(HINSTANCE, 'BREAK_SET24');
      fImages.AddResourceName(HINSTANCE, 'BULLET_GREEN24');
      fImages.AddResourceName(HINSTANCE, 'BULLET_BLACK24');
      fImages.AddResourceName(HINSTANCE, 'BREAK_REACHED24');
      fImages.AddResourceName(HINSTANCE, 'STEP24');
      fImages.AddResourceName(HINSTANCE, 'CAMERA_GO24');
      fImages.AddResourceName(HINSTANCE, 'WARNING24');
      AssignPng(fSyncEdit.GutterGlyph, 'LINK_EDIT24');
    end;
    iss32:
    begin
      fImages.Width:= 32;
      fImages.Height:= 32;
      fImages.AddResourceName(HINSTANCE, 'BREAK_SET32');
      fImages.AddResourceName(HINSTANCE, 'BULLET_GREEN32');
      fImages.AddResourceName(HINSTANCE, 'BULLET_BLACK32');
      fImages.AddResourceName(HINSTANCE, 'BREAK_REACHED32');
      fImages.AddResourceName(HINSTANCE, 'STEP32');
      fImages.AddResourceName(HINSTANCE, 'CAMERA_GO32');
      fImages.AddResourceName(HINSTANCE, 'WARNING32');
      AssignPng(fSyncEdit.GutterGlyph, 'LINK_EDIT32');
    end;
  end;

  fPositions := TCESynMemoPositions.create(self);
  fMultiDocSubject := TCEMultiDocSubject.create;

  //HighlightAllColor.Foreground := clNone;
  //HighlightAllColor.Background := clSilver;
  //HighlightAllColor.BackAlpha  := 70;
  //IdentifierMatchOptions:= [caseSensitive];
  //
  //LineHighlightColor.Background := color - $080808;
  //LineHighlightColor.Foreground := clNone;

  //fIndentGuideMarkup:= TSynEditMarkupFoldColors.Create(self);
  //MarkupManager.AddMarkUp(fIndentGuideMarkup);

  OptTabSize:= 4;
  OptIndentSize:= 4;
  OptTabSpaces:= true;
  OptSavingTrimSpaces:= true;
  OptSavingForceFinalEol:=false;
  OptAllowReadOnly:=true;

  fAutoCloseCurlyBrace:= autoCloseOnNewLineLexically;
  fAutoClosedPairs:= [autoCloseSquareBracket];

  fDastWorxExename:= exeFullName('dastworx' + exeExt);

  fDebugger := EntitiesConnector.getSingleService('ICEDebugger') as ICEDebugger;

  subjDocNew(TCEMultiDocSubject(fMultiDocSubject), self);
  EntitiesConnector.addObserver(self);
end;

destructor TCESynMemo.destroy;
begin
  saveCache;

  //fIndentGuideMarkup.Free;
  EntitiesConnector.removeObserver(self);
  subjDocClosing(TCEMultiDocSubject(fMultiDocSubject), self);
  fMultiDocSubject.Free;
  fPositions.Free;
  fCompletion.Free;
  fCallTipStrings.Free;
  fLexToks.Clear;
  fLexToks.Free;
  fSortDialog.Free;
  fDscannerResults.Free;

  if fTempFileName.fileExists then
    sysutils.DeleteFile(fTempFileName);

  inherited;
end;

procedure TCESynMemo.setGutterTransparent(value: boolean);
begin
  fTransparentGutter:=value;
  if fTransparentGutter then
  begin
    //Gutter.LineNumberPart.MarkupInfo.Background:= Color;
    //Gutter.SeparatorPart.MarkupInfo.Background:= Color;
    //Gutter.MarksPart.MarkupInfo.Background:= Color;
    //Gutter.ChangesPart.MarkupInfo.Background:= Color;
    //Gutter.CodeFoldPart.MarkupInfo.Background:= Color;
    //Gutter.Color:=Color;
  end
  else
  begin
    //Gutter.LineNumberPart.MarkupInfo.Background:= clBtnFace;
    //Gutter.SeparatorPart.MarkupInfo.Background:= clBtnFace;
    //Gutter.MarksPart.MarkupInfo.Background:= clBtnFace;
    //Gutter.ChangesPart.MarkupInfo.Background:= clBtnFace;
    //Gutter.CodeFoldPart.MarkupInfo.Background:= clBtnFace;
    //Gutter.Color:=clBtnFace;
  end;
end;

procedure TCESynMemo.setDefaultFontSize(value: Integer);
var
  old: Integer;
begin
  old := Font.Size;
  if value < 5 then
    value := 5;
  fDefaultFontSize:= value;
  if Font.Size = old then
    Font.Size := fDefaultFontSize;
end;

procedure TCESynMemo.setFocus;
begin
  inherited;
  //checkFileDate;
  highlightCurrentIdentifier;
  subjDocFocused(TCEMultiDocSubject(fMultiDocSubject), self);
end;

procedure TCESynMemo.showPage;
begin
  getMultiDocHandler.openDocument(fileName);
end;

procedure TCESynMemo.DoEnter;
begin
  inherited;
  checkFileDate;
  if not fFocusForInput then
    subjDocFocused(TCEMultiDocSubject(fMultiDocSubject), self);
  fFocusForInput := true;
  fScrollMemo.Visible:=false;
end;

procedure TCESynMemo.DoExit;
begin
  inherited;
  fFocusForInput := false;
  hideDDocs;
  hideCallTips;
  fScrollMemo.Visible:=false;
  if fCompletion.IsActive then
    fCompletion.Deactivate;
end;

procedure TCESynMemo.SetVisible(Value: Boolean);
begin
  inherited;
  if Value then
  begin
    setFocus;
    if not fCacheLoaded then
      loadCache;
    fCacheLoaded := true;
  end
  else
  begin
    hideDDocs;
    hideCallTips;
    fScrollMemo.Visible:=false;
    if fCompletion.IsActive then
      fCompletion.Deactivate;
  end;
end;

function TCESynMemo.getCaretX: integer;
var
  c: TATCaretItem;
begin
  result := 1;
  if Carets.Count = 0 then
    exit;
  c:= Carets[0];
  if not Strings.IsIndexValid(c.PosY) then
    exit;
  result := min(c.PosX, Strings.LinesLen[c.PosY]);
  result += 1;
end;

function TCESynMemo.getCaretY: integer;
begin
  result := Carets[0].PosY + 1;
end;

function TCESynMemo.getCaretXY: TPoint;
begin
  result := point(getCaretX, getCaretY);
end;

function TCESynMemo.getNormalizedSelRect: TRect;
var
  c: TATCaretItem;
  r: TValueRelationship;
begin
  result := Rect(0,0,0,0);
  if Carets.Count = 0 then
    exit;
  c:= Carets[0];
  if c.EndX = -1 then
    exit;
  r := CompareValue(c.EndY, c.PosY);
  case r of
  -1:
    begin
      result.Left:= c.EndX + 1;
      result.top := c.EndY + 1;
      result.Right:= c.PosX + 1;
      result.Bottom := c.PosY + 1;
    end;
  0:
    begin
      if c.EndX > c.PosX then
      begin
        result.Left:= c.PosX + 1;
        result.Right:= c.EndX + 1;
      end
      else
      begin
        result.Left:= c.EndX + 1;
        result.Right:= c.PosX + 1;
      end;
      result.top := c.EndY + 1;
      result.Bottom := c.PosY + 1;
    end;
  1:
    begin
      result.Left:= c.PosX + 1;
      result.top := c.PosY + 1;
      result.Right:= c.EndX + 1;
      result.Bottom := c.EndY + 1;
    end;
  end;
end;

procedure TCESynMemo.setCaretX(value: integer);
begin
  Carets[0].PosX := value - 1;
  DoGotoCaret(TATCaretEdge.cEdgeRight);
end;

procedure TCESynMemo.setCaretY(value: integer);
begin
  Carets[0].PosY := value - 1;
  DoGotoCaret(TATCaretEdge.cEdgeRight);
end;

procedure TCESynMemo.setCaretXY(value: TPoint);
begin
  setCaretX(value.x);
  setCaretY(value.y);
end;

procedure TCESynMemo.selectLineAtCaret();
var
  c: TATCaretItem;
begin
  c := Carets[0];
  if Strings.IsIndexValid(c.PosY) then
    DoSelect_Line(point(0, c.PosY));
end;

function TCESynMemo.lineTextAtCarret(): string;
var
  c: TATCaretItem;
begin
  c := Carets[0];
  Result := '';
  if Strings.IsIndexValid(c.PosY) then
    Result := Strings.LinesUTF8[c.PosY];
end;

function TCESynMemo.hasSelection: boolean;
var
  c: TATCaretItem;
begin
  c := Carets[0];
  Result := false;
  if Strings.IsIndexValid(c.PosY) then
    Result := c.EndX <> -1;
end;

function TCESynMemo.selTextUTF8: string;
begin
  Result := UTF8Encode(TextSelected);
end;

function TCESynMemo.indentationMode: TIndentationMode;
  function checkLine(index: integer): TIndentationMode;
  var
    u: string;
  begin
    result := imNone;
    u := strings.LinesUTF8[index];
    if (u.length > 0) and (u[1] = #9) then
      result := imTabs
    else if (u.length > 1) and (u[1..2] = '  ') then
      result := imSpaces;
  end;
var
  i: integer;
  t: integer = 0;
  s: integer = 0;
begin
  for i:= 0 to strings.count-1 do
  begin
    result := checkLine(i);
    t += byte(result = imTabs);
    s += byte(result = imSpaces);
  end;
  if (t <> 0) and (s <> 0) then
    result := imMixed
  else if t = 0 then
    result := imSpaces
  else if s = 0 then
    result := imTabs
  else
    result := imNone;
end;

function TCESynMemo.getCaretBytePosition: integer;
var
  x: integer;
  y: integer;
  i: integer;
begin
  result := 0;
  x := caretX;
  y := caretY;
  if (x - 1 > strings.LinesLen[y-1]) or (y > Strings.Count) then
    exit;
  for i:= 0 to y-2 do
    result += Strings.LinesLenPhysical[i];
  result += x;
end;

procedure TCESynMemo.setCaretBytePosition(value: integer);
var
  i: integer;
  s: integer = 0;
  e: integer = 0;
  r: integer = 0;
  p: TPoint;
begin
  for i := 0 to strings.Count-1 do
  begin
    s := e;
    r := value - s;
    e := s + strings.LinesLen[i] + length(cLineEndStrings[strings.LinesEnds[i]]);
    if (s <= value) and (value <= e) then
    begin
      p := point(r + 1, i + 1);
      caretXY := p;
      break;
    end;
  end;
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION Custom editor commands and shortcuts ----------------------------------}
procedure SetDefaultCoeditKeystrokes(ed: TSynEdit);
begin
  with ed do
  begin
    Keystrokes.Clear;

    //AddKey(ecUp, VK_UP, [], 0, []);
    //AddKey(ecSelUp, VK_UP, [ssShift], 0, []);
    //AddKey(ecScrollUp, VK_UP, [ssCtrl], 0, []);
    //AddKey(ecDown, VK_DOWN, [], 0, []);
    //AddKey(ecSelDown, VK_DOWN, [ssShift], 0, []);
    //AddKey(ecScrollDown, VK_DOWN, [ssCtrl], 0, []);
    //AddKey(ecLeft, VK_LEFT, [], 0, []);
    //AddKey(ecSelLeft, VK_LEFT, [ssShift], 0, []);
    //AddKey(ecWordLeft, VK_LEFT, [ssCtrl], 0, []);
    //AddKey(ecWordEndLeft, VK_LEFT, [ssCtrl,ssAlt], 0, []);
    //AddKey(ecWordEndRight, VK_RIGHT, [ssCtrl,ssAlt], 0, []);
    //AddKey(ecSelWordLeft, VK_LEFT, [ssShift,ssCtrl], 0, []);
    //AddKey(ecRight, VK_RIGHT, [], 0, []);
    //AddKey(ecSelRight, VK_RIGHT, [ssShift], 0, []);
    //AddKey(ecWordRight, VK_RIGHT, [ssCtrl], 0, []);
    //AddKey(ecSelWordRight, VK_RIGHT, [ssShift,ssCtrl], 0, []);
    //AddKey(ecPageDown, VK_NEXT, [], 0, []);
    //AddKey(ecSelPageDown, VK_NEXT, [ssShift], 0, []);
    //AddKey(ecPageBottom, VK_NEXT, [ssCtrl], 0, []);
    //AddKey(ecSelPageBottom, VK_NEXT, [ssShift,ssCtrl], 0, []);
    //AddKey(ecPageUp, VK_PRIOR, [], 0, []);
    //AddKey(ecSelPageUp, VK_PRIOR, [ssShift], 0, []);
    //AddKey(ecPageTop, VK_PRIOR, [ssCtrl], 0, []);
    //AddKey(ecSelPageTop, VK_PRIOR, [ssShift,ssCtrl], 0, []);
    //AddKey(ecLineStart, VK_HOME, [], 0, []);
    //AddKey(ecSelLineStart, VK_HOME, [ssShift], 0, []);
    //AddKey(ecEditorTop, VK_HOME, [ssCtrl], 0, []);
    //AddKey(ecSelEditorTop, VK_HOME, [ssShift,ssCtrl], 0, []);
    //AddKey(ecLineEnd, VK_END, [], 0, []);
    //AddKey(ecSelLineEnd, VK_END, [ssShift], 0, []);
    //AddKey(ecEditorBottom, VK_END, [ssCtrl], 0, []);
    //AddKey(ecSelEditorBottom, VK_END, [ssShift,ssCtrl], 0, []);
    //AddKey(ecToggleMode, VK_INSERT, [], 0, []);
    //AddKey(ecDeleteChar, VK_DELETE, [], 0, []);
    //AddKey(ecDeleteLastChar, VK_BACK, [], 0, []);
    //AddKey(ecDeleteLastWord, VK_BACK, [ssCtrl], 0, []);
    //AddKey(ecLineBreak, VK_RETURN, [], 0, []);
    //AddKey(ecSelectAll, ord('A'), [ssCtrl], 0, []);
    //AddKey(ecCopy, ord('C'), [ssCtrl], 0, []);
    //AddKey(ecBlockIndent, ord('I'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecInsertLine, ord('N'), [ssCtrl], 0, []);
    //AddKey(ecDeleteWord, ord('T'), [ssCtrl], 0, []);
    //AddKey(ecBlockUnindent, ord('U'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecPaste, ord('V'), [ssCtrl], 0, []);
    //AddKey(ecCut, ord('X'), [ssCtrl], 0, []);
    //AddKey(ecDeleteLine, ord('Y'), [ssCtrl], 0, []);
    //AddKey(ecDeleteEOL, ord('Y'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecUndo, ord('Z'), [ssCtrl], 0, []);
    //AddKey(ecRedo, ord('Z'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecFoldLevel1, ord('1'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel2, ord('2'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel3, ord('3'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel4, ord('4'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel5, ord('5'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel6, ord('6'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel7, ord('7'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel8, ord('8'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel9, ord('9'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldLevel0, ord('0'), [ssAlt,ssShift], 0, []);
    //AddKey(ecFoldCurrent, ord('-'), [ssAlt,ssShift], 0, []);
    //AddKey(ecUnFoldCurrent, ord('+'), [ssAlt,ssShift], 0, []);
    //AddKey(EcToggleMarkupWord, ord('M'), [ssAlt], 0, []);
    //AddKey(ecNormalSelect, ord('N'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecColumnSelect, ord('C'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecLineSelect, ord('L'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecTab, VK_TAB, [], 0, []);
    //AddKey(ecShiftTab, VK_TAB, [ssShift], 0, []);
    //AddKey(ecMatchBracket, ord('B'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecColSelUp, VK_UP,    [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelDown, VK_DOWN,  [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelLeft, VK_LEFT, [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelRight, VK_RIGHT, [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelPageDown, VK_NEXT, [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelPageBottom, VK_NEXT, [ssAlt, ssShift,ssCtrl], 0, []);
    //AddKey(ecColSelPageUp, VK_PRIOR, [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelPageTop, VK_PRIOR, [ssAlt, ssShift,ssCtrl], 0, []);
    //AddKey(ecColSelLineStart, VK_HOME, [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelLineEnd, VK_END, [ssAlt, ssShift], 0, []);
    //AddKey(ecColSelEditorTop, VK_HOME, [ssAlt, ssShift,ssCtrl], 0, []);
    //AddKey(ecColSelEditorBottom, VK_END, [ssAlt, ssShift,ssCtrl], 0, []);
    //AddKey(ecSynPSyncroEdStart, ord('E'), [ssCtrl], 0, []);
    //AddKey(ecSynPSyncroEdEscape, ord('E'), [ssCtrl, ssShift], 0, []);
    //AddKey(ecCompletionMenu, ord(' '), [ssCtrl], 0, []);
    //AddKey(ecJumpToDeclaration, VK_UP, [ssCtrl,ssShift], 0, []);
    //AddKey(ecPreviousLocation, 0, [], 0, []);
    //AddKey(ecNextLocation, 0, [], 0, []);
    //AddKey(ecRecordMacro, ord('R'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecPlayMacro, ord('P'), [ssCtrl,ssShift], 0, []);
    //AddKey(ecShowDdoc, 0, [], 0, []);
    //AddKey(ecShowCallTips, 0, [], 0, []);
    //AddKey(ecCurlyBraceClose, 0, [], 0, []);
    //AddKey(ecCommentSelection, ord('/'), [ssCtrl], 0, []);
    //AddKey(ecSwapVersionAllNone, 0, [], 0, []);
    //AddKey(ecRenameIdentifier, VK_F2, [], 0, []);
    //AddKey(ecCommentIdentifier, 0, [], 0, []);
    //AddKey(ecShowPhobosDoc, VK_F1, [], 0, []);
    //AddKey(ecPreviousChangedArea, VK_UP, [ssAlt], 0, []);
    //AddKey(ecNextChangedArea, VK_DOWN, [ssAlt], 0, []);
    //AddKey(ecLowerCaseWordOrSel, 0, [], 0, []);
    //AddKey(ecUpperCaseWordOrSel, 0, [], 0, []);
    //AddKey(ecSortLines, 0, [], 0, []);
    //AddKey(ecPrevProtGrp, 0, [], 0, []);
    //AddKey(ecNextProtGrp, 0, [], 0, []);
    //AddKey(ecAddBreakpoint, 0, [], 0, []);
    //AddKey(ecRemoveBreakpoint, 0, [], 0, []);
    //AddKey(ecToggleBreakpoint, 0, [], 0, []);
    //AddKey(ecInsertDdocTemplate, 0, [], 0, []);
    //AddKey(ecPrevWarning, 0, [], 0, []);
    //AddKey(ecNextWarning, 0, [], 0, []);
    //AddKey(ecGotoLine, 0, [], 0, []);
    //AddKey(ecShowCurlineWarning, 0, [], 0, []);
  end;
end;

function CustomStringToCommand(const Ident: string; var Int: Longint): Boolean;
begin
  case Ident of
    'ecCompletionMenu':     begin Int := ecCompletionMenu; exit(true); end;
    'ecJumpToDeclaration':  begin Int := ecJumpToDeclaration; exit(true); end;
    'ecPreviousLocation':   begin Int := ecPreviousLocation; exit(true); end;
    'ecNextLocation':       begin Int := ecNextLocation; exit(true); end;
    'ecRecordMacro':        begin Int := ecRecordMacro; exit(true); end;
    'ecPlayMacro':          begin Int := ecPlayMacro; exit(true); end;
    'ecShowDdoc':           begin Int := ecShowDdoc; exit(true); end;
    'ecShowCallTips':       begin Int := ecShowCallTips; exit(true); end;
    'ecCurlyBraceClose':    begin Int := ecCurlyBraceClose; exit(true); end;
    'ecCommentSelection':   begin Int := ecCommentSelection; exit(true); end;
    'ecSwapVersionAllNone': begin Int := ecSwapVersionAllNone; exit(true); end;
    'ecRenameIdentifier':   begin Int := ecRenameIdentifier; exit(true); end;
    'ecCommentIdentifier':  begin Int := ecCommentIdentifier; exit(true); end;
    'ecShowPhobosDoc':      begin Int := ecShowPhobosDoc; exit(true); end;
    'ecNextChangedArea':    begin Int := ecNextChangedArea; exit(true); end;
    'ecPreviousChangedArea':begin Int := ecPreviousChangedArea; exit(true); end;
    'ecUpperCaseWordOrSel': begin Int := ecUpperCaseWordOrSel; exit(true); end;
    'ecLowerCaseWordOrSel': begin Int := ecLowerCaseWordOrSel; exit(true); end;
    'ecSortLines':          begin Int := ecSortLines; exit(true); end;
    'ecNextProtGrp':        begin Int := ecNextProtGrp; exit(true); end;
    'ecPrevProtGrp':        begin Int := ecPrevProtGrp; exit(true); end;
    'ecAddBreakpoint':      begin Int := ecAddBreakpoint; exit(true); end;
    'ecRemoveBreakpoint':   begin Int := ecRemoveBreakpoint; exit(true); end;
    'ecToggleBreakpoint':   begin Int := ecToggleBreakpoint; exit(true); end;
    'ecInsertDdocTemplate': begin Int := ecInsertDdocTemplate; exit(true); end;
    'ecPrevWarning':        begin Int := ecPrevWarning; exit(true); end;
    'ecNextWarning':        begin Int := ecNextWarning; exit(true); end;
    'ecGotoLine':           begin Int := ecGotoLine; exit(true); end;
    'ecShowCurlineWarning': begin Int := ecShowCurlineWarning; exit(true); end;
    else exit(false);
  end;
end;

function CustomCommandToSstring(Int: Longint; var Ident: string): Boolean;
begin
  case Int of
    ecCompletionMenu:     begin Ident := 'ecCompletionMenu'; exit(true); end;
    ecJumpToDeclaration:  begin Ident := 'ecJumpToDeclaration'; exit(true); end;
    ecPreviousLocation:   begin Ident := 'ecPreviousLocation'; exit(true); end;
    ecNextLocation:       begin Ident := 'ecNextLocation'; exit(true); end;
    ecRecordMacro:        begin Ident := 'ecRecordMacro'; exit(true); end;
    ecPlayMacro:          begin Ident := 'ecPlayMacro'; exit(true); end;
    ecShowDdoc:           begin Ident := 'ecShowDdoc'; exit(true); end;
    ecShowCallTips:       begin Ident := 'ecShowCallTips'; exit(true); end;
    ecCurlyBraceClose:    begin Ident := 'ecCurlyBraceClose'; exit(true); end;
    ecCommentSelection:   begin Ident := 'ecCommentSelection'; exit(true); end;
    ecSwapVersionAllNone: begin Ident := 'ecSwapVersionAllNone'; exit(true); end;
    ecRenameIdentifier:   begin Ident := 'ecRenameIdentifier'; exit(true); end;
    ecCommentIdentifier:  begin Ident := 'ecCommentIdentifier'; exit(true); end;
    ecShowPhobosDoc:      begin Ident := 'ecShowPhobosDoc'; exit(true); end;
    ecNextChangedArea:    begin Ident := 'ecNextChangedArea'; exit(true); end;
    ecPreviousChangedArea:begin Ident := 'ecPreviousChangedArea'; exit(true); end;
    ecUpperCaseWordOrSel: begin Ident := 'ecUpperCaseWordOrSel'; exit(true); end;
    ecLowerCaseWordOrSel: begin Ident := 'ecLowerCaseWordOrSel'; exit(true); end;
    ecSortLines:          begin Ident := 'ecSortLines'; exit(true); end;
    ecNextProtGrp:        begin Ident := 'ecNextProtGrp'; exit(true); end;
    ecPrevProtGrp:        begin Ident := 'ecPrevProtGrp'; exit(true); end;
    ecAddBreakpoint:      begin Ident := 'ecAddBreakpoint'; exit(true); end;
    ecRemoveBreakpoint:   begin Ident := 'ecRemoveBreakpoint'; exit(true); end;
    ecToggleBreakpoint:   begin Ident := 'ecToggleBreakpoint'; exit(true); end;
    ecInsertDdocTemplate: begin Ident := 'ecInsertDdocTemplate'; exit(true); end;
    ecPrevWarning:        begin Ident := 'ecPrevWarning'; exit(true); end;
    ecNextWarning:        begin Ident := 'ecNextWarning'; exit(true); end;
    ecGotoLine:           begin Ident := 'ecGotoLine'; exit(true); end;
    ecShowCurlineWarning: begin Ident := 'ecShowCurlineWarning'; exit(true); end;
    else exit(false);
  end;
end;

procedure TCESynMemo.DoCommand(ACmd: integer; const AText: atString = '');
begin
  inherited;
  case ACmd of
    ecPaste: patchClipboardIndentation;
    ecCompletionMenu:
    begin
      fCanAutoDot:=false;
      if not fIsDSource and not alwaysAdvancedFeatures then
        exit;
      //fCompletion.Execute(GetWordAtRowCol(LogicalCaretXY),
      //  ClientToScreen(point(CaretXPix, CaretYPix + LineHeight)));
    end;
    ecPreviousLocation:
      fPositions.back;
    ecNextLocation:
      fPositions.next;
    ecShowDdoc:
    begin
      hideCallTips;
      hideDDocs;
      if not fIsDSource and not alwaysAdvancedFeatures then
        exit;
      showDDocs;
    end;
    ecShowCallTips:
    begin
      hideCallTips;
      hideDDocs;
      if not fIsDSource and not alwaysAdvancedFeatures then
        exit;
      showCallTips(true);
    end;
    ecCurlyBraceClose:
      curlyBraceCloseAndIndent;
    ecCommentSelection:
      commentSelection;
    ecSwapVersionAllNone:
      invertVersionAllNone;
    ecRenameIdentifier:
      renameIdentifier;
    ecCommentIdentifier:
      commentIdentifier;
    ecShowPhobosDoc:
      ShowPhobosDoc;
    ecNextChangedArea:
      goToChangedArea(true);
    ecPreviousChangedArea:
      goToChangedArea(false);
    ecUpperCaseWordOrSel:
      setSelectionOrWordCase(true);
    ecLowerCaseWordOrSel:
      setSelectionOrWordCase(false);
    ecSortLines:
      sortLines;
    ecPrevProtGrp:
      previousProtectionGroup;
    ecNextProtGrp:
      nextProtectionGroup;
    ecAddBreakpoint:
      addCurLineBreakPoint;
    ecRemoveBreakpoint:
      removeCurLineBreakPoint;
    ecToggleBreakpoint:
      toggleCurLineBreakpoint;
    ecInsertDdocTemplate:
      insertDdocTemplate;
    ecPrevWarning:
      goToWarning(false);
    ecNextWarning:
      goToWarning(true);
    ecGotoLine:
      gotoLinePrompt;
    ecShowCurlineWarning:
      showCurLineWarning;
  end;
  //if fOverrideColMode and not SelAvail then
  //begin
  //  fOverrideColMode := false;
  //  Options := Options - [eoScrollPastEol];
  //end;
end;

procedure TCESynMemo.insertLeadingDDocSymbol(c: char);
begin
  strings.BeginUndoGroup;
  if ((CaretX-1) and 1) = 0 then
    DoCommand(cCommand_TextInsert, ' ');
  DoCommand(cCommand_TextInsert, c);
  strings.EndUndoGroup;
end;

procedure TCESynMemo.curlyBraceCloseAndIndent;
var
  i: integer;
  beg: string = '';
  numTabs: integer = 0;
  numSpac: integer = 0;
begin
  if not fIsDSource and not alwaysAdvancedFeatures then
    exit;

  i := caretY - 1;
  while true do
  begin
    if i < 0 then
      break;
    beg := Strings.LinesUTF8[i];
    if (Pos('{', beg) = 0) then
      i -= 1
    else
      break;
  end;

  for i:= 1 to beg.length do
  begin
    case beg[i] of
      #9: numTabs += 1;
      ' ': numSpac += 1;
      else break;
    end;
  end;
  numTabs += numSpac div OptTabSize;

  //Strings.BeginUndoGroup;

  DoCommand(cCommand_TextInsertEmptyBelow);
  DoCommand(cCommand_TextInsertEmptyBelow);
  for i:= 0 to numTabs-1 do DoCommand(cCommand_KeyTab);
  DoCommand(cCommand_TextInsert, '}');

  DoCommand(cCommand_KeyUp);
  DoCommand(cCommand_TextDeleteToLineBegin);
  for i:= 0 to numTabs do DoCommand(cCommand_KeyTab);

  //strings.EndUndoGroup
end;

procedure TCESynMemo.commentSelection;
  procedure commentHere;
  begin
    DoCommand(cCommand_TextInsert, '//');
  end;
  procedure unCommentHere;
  begin
    DoCommand(cCommand_KeyDelete);
    DoCommand(cCommand_KeyDelete);
  end;
var
  i, j, dx, lx, numUndo ,e: integer;
  line: string;
  mustUndo: boolean = false;
  pt, cp: TPoint;
  rc: TRect;
begin
  if not hasSelection then
  begin
    i := CaretX;
    line := TrimLeft(lineTextAtCarret);
    dx := lineTextAtCarret.length - line.length;
    mustUndo := (line.length > 1) and (line[1..2] = '//');
    strings.BeginUndoGroup;
    CaretX := dx + 1;
    if not mustUndo then
    begin
      commentHere;
      CaretX:= i+2;
    end
    else
    begin
      unCommentHere;
      CaretX:= i-2;
    end;
    strings.EndUndoGroup;
  end else
  begin
    mustUndo := false;
    rc := normalizedSelRect;
    pt.X:= high(pt.X);
    cp := CaretXY;
    numUndo := 0;
    for i := rc.top-1 to rc.bottom-1 do
    begin
      line := TrimLeft(strings.LinesUTF8[i]);
      lx := strings.LinesUTF8[i].length - line.length + 1;
      if (lx < pt.X) and not line.isEmpty then
        pt.X:= lx;
      if (line.length > 1) and (line[1..2] = '//') then
        numUndo += 1;
    end;
    e := rc.Height + 1;
    if numUndo = 0 then
      mustUndo := false
    else if numUndo = e then
      mustUndo := true;
    strings.BeginUndoGroup;
    e := Carets[0].EndY + 1;
    Carets[0].EndY := -1;
    Carets[0].EndX := -1;
    for i := rc.top to rc.bottom do
    begin
      pt.Y:= i;
      caretXY := pt;
      while CaretX < pt.X do
        DoCommand(cCommand_TextInsert, ' ');
      if not mustUndo then
        commentHere
      else
        unCommentHere;
    end;
    if not mustUndo then
      cp.X += 2
    else
      cp.X -= 2;
    CaretXY := cp;
    strings.EndUndoGroup;
  end;
end;

procedure TCESynMemo.commentIdentifier;
var
  str: string;
  x, x0, x1: integer;
  comBeg: boolean = false;
  comEnd: boolean = false;
  comment:boolean = true;
  attrib: TSynHighlighterAttributes;
begin
  //if not GetHighlighterAttriAtRowColEx(CaretXY, str, x0, x, attrib) then
  //  exit;
  //if str.isEmpty then
  //  exit;
  //
  //str := LineText;
  //x := LogicalCaretXY.X;
  //
  //ExecuteCommand(ecWordEndRight, #0, nil);
  //x1 := LogicalCaretXY.X;
  //while true do
  //begin
  //  if (str[x1] in ['*', '+']) and (x1 < str.length) and (str[x1+1] = '/') then
  //  begin
  //    comEnd:=true;
  //    break;
  //  end;
  //  if not isBlank(str[x1]) then
  //    break;
  //  ExecuteCommand(ecRight, #0, nil);
  //  x1 += 1;
  //  if x1 = str.length then
  //    break;
  //end;
  //
  //LogicalCaretXY := point(x, LogicalCaretXY.Y);
  //ExecuteCommand(ecWordLeft, #0, nil);
  //x0 := LogicalCaretXY.X - 1;
  //if (x0 > 1) then while true do
  //begin
  //  if (x0 > 1) and (str[x0] in ['*', '+']) and (str[x0-1] = '/') then
  //  begin
  //    x0 -= 1;
  //    comBeg:=true;
  //    break;
  //  end;
  //  if not isBlank(str[x0]) then
  //    break;
  //  ExecuteCommand(ecLeft, #0, nil);
  //  x0 -= 1;
  //  if x0 = 1 then
  //    break;
  //end;
  //
  //comment := not comBeg and not comEnd;
  //LogicalCaretXY := point(x, LogicalCaretXY.Y);
  //if comment then
  //begin
  //  BeginUndoBlock;
  //  ExecuteCommand(ecWordLeft, '', nil);
  //  ExecuteCommand(ecChar, '/', nil);
  //  ExecuteCommand(ecChar, '*', nil);
  //  ExecuteCommand(ecWordEndRight, '', nil);
  //  ExecuteCommand(ecChar, '*', nil);
  //  ExecuteCommand(ecChar, '/', nil);
  //  EndUndoBlock;
  //end else
  //begin
  //  BeginUndoBlock;
  //  LogicalCaretXY := point(x1, LogicalCaretXY.Y);
  //  ExecuteCommand(ecDeleteChar, '', nil);
  //  ExecuteCommand(ecDeleteChar, '', nil);
  //  LogicalCaretXY := point(x0, LogicalCaretXY.Y);
  //  ExecuteCommand(ecDeleteChar, '', nil);
  //  ExecuteCommand(ecDeleteChar, '', nil);
  //  EndUndoBlock;
  //end;
end;

procedure TCESynMemo.invertVersionAllNone;
var
  i: integer;
  c: char;
  tok, tok1, tok2: PLexToken;
  cp, st, nd: TPoint;
  p0, p1: TPoint;
  rc: TRect;
  sel: boolean;
begin
  fLexToks.Clear;
  lex(Strings.TextString_UTF8, fLexToks, nil, [lxoNoComments]);
  cp := CaretXY;
  sel:= hasSelection;
  rc := normalizedSelRect;
  strings.BeginUndoGroup;
  for i := fLexToks.Count-1 downto 2 do
  begin
    tok := PLexToken(fLexToks[i]);

    if sel and ((tok^.position.Y < rc.Top)
      or (tok^.position.Y > rc.Bottom)) then
        continue;
    if ((tok^.Data <> 'all') and (tok^.Data <> 'none'))
      or (tok^.kind <> ltkIdentifier) or (i < 2) then
        continue;

    tok1 := PLexToken(fLexToks[i-2]);
    tok2 := PLexToken(fLexToks[i-1]);

    if  ((tok1^.kind = ltkKeyword) and (tok1^.data = 'version')
      and (tok2^.kind = ltkSymbol) and (tok2^.data = '(')) then
    begin
      CaretXY := tok^.position;
      case tok^.Data of
        'all':
        begin
          strings.TextDeleteRange(CaretX, CaretY - 1, CaretX + 3, CaretY - 1, p0, p1);
          strings.TextInsert(CaretX, CaretY - 1, 'none', false, p0, p1);
        end;
        'none':
        begin
          strings.TextDeleteRange(CaretX, CaretY - 1, CaretX + 4, CaretY - 1, p0, p1);
          strings.TextInsert(CaretX, CaretY - 1, 'all', false, p0, p1);
        end;
      end;
    end;
  end;
  strings.EndUndoGroup;
  CaretXY := cp;
end;

procedure TCESynMemo.renameIdentifier;
var
  locs: TIntOpenArray = nil;
  old, idt, line: string;
  i, j, loc: integer;
  p: TPoint;
  c: char;
const
  IdentChars = ['a'..'z', 'A'..'Z', '0'..'9', '_'];
begin
  if not DcdWrapper.available then
    exit;

  p := CaretXY;
  line := lineTextAtCarret;
  if (CaretX = 1) or not (line[caretX] in IdentChars) or
    not (line[caretX-1] in IdentChars) then
      exit;

  old := TextCurrentWord;
  DcdWrapper.getLocalSymbolUsageFromCursor(locs);
  if length(locs) = 0 then
  begin
    dlgOkInfo('Unknown, ambiguous or non-local symbol for "'+ old +'"');
    exit;
  end;

  idt := 'new identifier for "' + old + '"';
  idt := InputBox('Local identifier renaming', idt, old);
  if idt.isEmpty or idt.isBlank then
    exit;

  Strings.BeginUndoGroup;
  for i:= high(locs) downto 0 do
  begin
    loc := locs[i];
    if loc = -1 then
      continue;

    caretBytePosition := loc;
    for j in [0..old.length-1] do
      DoCommand(cCommand_KeyDelete);
    DoCommand(cCommand_TextInsert, idt);
  end;
  strings.EndUndoGroup;

  CaretXY := p;
end;

procedure TCESynMemo.ShowPhobosDoc;
var
  str: string;
  pth: string;
  rac: string;
  idt: string = '';
  pos: integer;
  rng: TStringRange = (ptr:nil; pos:0; len: 0);
  mem: TMemoryStream;
  src: string;
  procedure errorMessage(const msg: string);
  begin
    // parameter for doc racine is a folder
    if rac[rac.length] in ['/','\'] then
      rac += 'index.html'
    else if rac.dirExists then
      rac += DirectorySeparator + 'index.html'
    else
      rac += '/' + 'index.html';

    if dlgYesNo(format('%s.%sOpen the documentation index anyway ?',
      [msg, LineEnding])) = mrYes then
        OpenURL(rac);
  end;
begin
  if fPhobosDocRoot.dirExists then
    rac := 'file://' + fPhobosDocRoot
  else
    rac := fPhobosDocRoot;
  if rac.isEmpty then
    rac := 'https://dlang.org/phobos/index.html';
  DcdWrapper.getDeclFromCursor(str, pos);
  if not str.fileExists then
  begin
    errorMessage('The source where the symbol is declared is not existing');
    exit;
  end;
  // verify that the decl is in phobos
  pth := str;
  while true do
  begin
    if pth.extractFilePath = pth then
    begin
      errorMessage('The source where the symbol is declared does not seem' +
        ' to be part of Phobos or the D runtime');
      exit;
    end;
    pth := pth.extractFilePath;
    setLength(pth,pth.length-1);
    if (pth.extractFilename = 'phobos') or (pth.extractFilename = 'core')
      or (pth.extractFilename = 'etc') then
        break;
  end;
  // get the declaration name
  if pos <> -1 then
  begin
    mem := TMemoryStream.Create;
    try
      mem.LoadFromFile(str);
      setLength(src, mem.Size);
      mem.Read(src[1], mem.Size);
      rng.init(src);
      rng.popFrontN(pos);
      idt := '.html#.' + rng.nextWord;
    finally
      mem.free;
    end;
  end;
  // guess the htm file + anchor
  rng.init(str);
  while true do
  begin
    if rng.empty then
    begin
      errorMessage('Failed to determine the matching HTML file');
      exit;
    end;
    rng.popUntil(DirectorySeparator);
    if not rng.empty then
      rng.popFront;
    if rng.startsWith('std' + DirectorySeparator) or rng.startsWith('core' + DirectorySeparator)
      or rng.startsWith('etc' + DirectorySeparator) then
        break;
  end;
  pth := rac;
  while not rng.empty do
  begin
    pth += rng.takeUntil([DirectorySeparator, '.']).yield;
    if rng.startsWith('.d') then
      break;
    pth += '_';
    rng.popFront;
  end;
  pth += idt;
  {$IFDEF WINDOWS}
  if fPhobosDocRoot.dirExists then
    for i:= 1 to pth.length do
      if pth[i] = '\' then
        pth[i] := '/';
  {$ENDIF}
  OpenURL(pth);
end;

procedure TCESynMemo.nextChangedArea;
begin
  goToChangedArea(true);
end;

procedure TCESynMemo.previousChangedArea;
begin
  goToChangedArea(false);
end;

procedure TCESynMemo.previousWarning;
begin
  goToWarning(false);
end;

procedure TCESynMemo.nextWarning;
begin
  goToWarning(true);
end;

procedure TCESynMemo.gotoLinePrompt;
var
  d: string;
  v: string;
  i: integer;
begin
  d := caretY.ToString;
  v := InputBox('Goto line', 'line number', d);
  if v.isNotEmpty and not v.Equals(d) then
  begin
    i := v.toIntNoExcept;
    if i <> -1 then
    begin
      if i < 1 then
        i := 1
      else if i > Strings.Count then
        i := Strings.Count;
      CaretY:= i;
    end;
  end;
end;

procedure TCESynMemo.showWarningForLine(line: integer);
var
  s: string;
  p: TPoint;
  c: TPoint = (x: 0; y: 0);
begin
  s := getDscannerWarning(line);
  if s.isNotEmpty then
  begin
    p.x := 0;
    p.y := line;
    p := CaretPosToClientPos(p);
    c := ClientToScreen(c);
    p.Offset(c);
    s := 'Warning(s):' + LineEnding + s;
    fDDocWin.FontSize := Font.Size;
    fDDocWin.HintRect := fDDocWin.CalcHintRect(0, s, nil);
    fDDocWin.OffsetHintRect(p, Font.Size);
    fDDocWin.ActivateHint(fDDocWin.HintRect, s);
  end;
end;

procedure TCESynMemo.showCurLineWarning;
begin
  showWarningForLine(CaretY);
end;

procedure TCESynMemo.goToChangedArea(next: boolean);
var
  i: integer;
  s: TATLineState;
  d: integer;
  b: integer = 0;
  p: TPoint;
begin
  i := CaretY - 1;
  s := Strings.LinesState[i];
  case next of
    true: begin d := 1; b := Strings.count-1; end;
    false:d := -1;
  end;
  if i = b then
    exit;
  // exit the current area if it's modified
  while s <> cLineStateNone do
  begin
    s := Strings.LinesState[i];
    if i = b then
      exit;
    i += d;
  end;
  // find next modified area
  while s = cLineStateNone do
  begin
    s := Strings.LinesState[i];
    if i = b then
      break;
    i += d;
  end;
  // goto area beg/end
  if (s <> cLineStateNone) and (i <> CaretY + 1) then
  begin
    p.X:= 1;
    p.Y:= i + 1 - d;
    caretXY := p;
    //NOTE-csynedit: Was undoable GOTO necessary here ?
    //ExecuteCommand(ecGotoXY, #0, @p);
  end;
end;

procedure TCESynMemo.goToProtectionGroup(next: boolean);
var
  i: integer;
  tk0, tk1: PLexToken;
  tk: PLexToken = nil;
begin
  fLexToks.Clear;
  lex(Strings.TextString_UTF8, fLexToks, nil, [lxoNoComments, lxoNoWhites]);
  for i:= 0 to fLexToks.Count-2 do
  begin
    tk0 := fLexToks[i];
    tk1 := fLexToks[i+1];
    if not next then
    begin
      if tk0^.position.Y >= caretY then
        break;
    end
    else if tk0^.position.Y <= caretY then
      continue;
    if tk0^.kind = ltkKeyword then
    case tk0^.Data of
      'public','private','protected','package','export':
        if (tk1^.kind = ltkSymbol) and (tk1^.Data[1] in ['{',':']) then
        begin
          tk := tk0;
          if next then
            break;
        end;
    end;
  end;
  if assigned(tk) then
  begin
    //NOTE-csynedit: Was undoable GOTO necessary here ?
    //ExecuteCommand(ecGotoXY, #0, @tk^.position);
    caretXY := tk^.position;
  end;
end;

procedure TCESynMemo.goToWarning(next: boolean);
var
  i: integer;
  j: integer = -1;
begin
  if not next then
  begin
    for i:= 0 to fDscannerResults.count-1 do
    begin
      j := i - 1;
      if fDscannerResults.item[i]^.line >= caretY then
        break;
    end;
    if j <> -1 then
    begin
      CaretY:= fDscannerResults.item[j]^.line;
      //EnsureCursorPosVisible;
    end;
  end
  else
  begin
    for i:= fDscannerResults.count-1 downto 0 do
    begin
      j := i + 1;
      if fDscannerResults.item[i]^.line <= caretY then
        break;
    end;
    if (j <> -1) and (j < fDscannerResults.count) then
    begin
      CaretY:= fDscannerResults.item[j]^.line;
      //EnsureCursorPosVisible;
    end;
  end;
end;

procedure TCESynMemo.previousProtectionGroup;
begin
  goToProtectionGroup(false);
end;

procedure TCESynMemo.nextProtectionGroup;
begin
  goToProtectionGroup(true);
end;

function TCESynMemo.implementMain: THasMain;
var
  res: char = '0';
  prc: TProcess;
  src: string;
begin
  if fDastWorxExename.length = 0 then
    exit(mainDefaultBehavior);
  src := Strings.TextString_UTF8;
  prc := TProcess.Create(nil);
  try
    prc.Executable:= fDastWorxExename;
    prc.Parameters.Add('-m');
    prc.Options := [poUsePipes{$IFDEF WINDOWS}, poNewConsole{$ENDIF}];
    prc.ShowWindow := swoHIDE;
    prc.Execute;
    prc.Input.Write(src[1], src.length);
    prc.CloseInput;
    prc.Output.Read(res, 1);
    while prc.Running do
      sleep(1);
  finally
    prc.Free;
  end;
  case res = '1' of
    false:result := mainNo;
    true: result := mainYes;
  end;
end;

procedure TCESynMemo.autoClosePair(value: TAutoClosedPair);
var
  i, p: integer;
  tk0, tk1: PLexToken;
  str: string;
begin
  fLexToks.Clear;
  if value in [autoCloseBackTick, autoCloseDoubleQuote] then
  begin
    p := caretBytePosition;
    lex(strings.TextString_UTF8, fLexToks);
    for i:=0 to fLexToks.Count-2 do
    begin
      tk0 := fLexToks[i];
      tk1 := fLexToks[i+1];
      if (tk0^.offset+1 <= p) and (p < tk1^.offset+2) and
        (tk0^.kind in [ltkString, ltkComment]) then
          exit;
    end;
    tk0 := fLexToks[fLexToks.Count-1];
    if (tk0^.offset+1 <= p) and (tk0^.kind <> ltkIllegal) then
      exit;
  end
  else if value = autoCloseSingleQuote then
  begin
    p := caretBytePosition;
    lex(strings.TextString_UTF8, fLexToks);
    for i:=0 to fLexToks.Count-2 do
    begin
      tk0 := fLexToks[i];
      tk1 := fLexToks[i+1];
      if (tk0^.offset+1 <= p) and (p < tk1^.offset+2) and
        (tk0^.kind in [ltkChar, ltkComment]) then
          exit;
    end;
    tk0 := fLexToks[fLexToks.Count-1];
    if (tk0^.offset+1 <= p) and (tk0^.kind <> ltkIllegal) then
      exit;
  end
  else if value = autoCloseSquareBracket then
  begin
    p := caretBytePosition;
    lex(strings.TextString_UTF8, fLexToks);
    for i:=0 to fLexToks.Count-2 do
    begin
      tk0 := fLexToks[i];
      tk1 := fLexToks[i+1];
      if (tk0^.offset+1 <= p) and (p < tk1^.offset+2) and
        (tk0^.kind = ltkComment) then
          exit;
    end;
    tk0 := fLexToks[fLexToks.Count-1];
    if (tk0^.offset+1 <= p) and (tk0^.kind <> ltkIllegal) then
      exit;
    str := lineTextAtCarret;
    i := caretBytePosition;
    if (i <= str.length) and (str[i] = ']') then
      exit;
  end;
  strings.BeginUndoGroup;
  DoCommand(cCommand_TextInsert, autoClosePair2Char[value]);
  DoCommand(cCommand_KeyLeft);
  strings.EndUndoGroup;
end;

procedure TCESynMemo.setSelectionOrWordCase(upper: boolean);
const
  c: array[boolean] of integer = (cCommand_TextCaseLower, cCommand_TextCaseUpper);
begin
  strings.BeginUndoGroup;
  DoCommand(c[upper]);
  strings.EndUndoGroup;
end;

procedure TCESynMemo.sortSelectedLines(descending, caseSensitive: boolean);
var
  i,j: integer;
  lne: string;
  lst: TStringListUTF8;
  pt0: TPoint;
begin
  //if BlockEnd.Y - BlockBegin.Y < 1 then
  //  exit;
  //lst := TStringListUTF8.Create;
  //try
  //  BeginUndoBlock;
  //  for i:= BlockBegin.Y-1 to BlockEnd.Y-1 do
  //    lst.Add(lines[i]);
  //  pt0 := BlockBegin;
  //  pt0.X:=1;
  //  ExecuteCommand(ecGotoXY, #0, @pt0);
  //  lst.CaseSensitive:=caseSensitive;
  //  if not caseSensitive then
  //    lst.Sorted:=true;
  //  case descending of
  //    false: for i:= 0 to lst.Count-1 do
  //      begin
  //        ExecuteCommand(ecDeleteLine, #0, nil);
  //        ExecuteCommand(ecInsertLine, #0, nil);
  //        lne := lst[i];
  //        for j := 1 to lne.length do
  //          ExecuteCommand(ecChar, lne[j], nil);
  //        ExecuteCommand(ecDown, #0, nil);
  //      end;
  //    true: for i:= lst.Count-1 downto 0 do
  //      begin
  //        ExecuteCommand(ecDeleteLine, #0, nil);
  //        ExecuteCommand(ecInsertLine, #0, nil);
  //        lne := lst[i];
  //        for j := 1 to lne.length do
  //          ExecuteCommand(ecChar, lne[j], nil);
  //        ExecuteCommand(ecDown, #0, nil);
  //      end;
  //  end;
  //  EndUndoBlock;
  //finally
  //  lst.Free;
  //end;
end;

procedure TCESynMemo.sortLines;
begin
  if not assigned(fSortDialog) then
    fSortDialog := TSortDialog.construct(self);
  fSortDialog.Show;
end;

procedure TCESynMemo.addCurLineBreakPoint;
begin
  if not findBreakPoint(CaretY) then
    addBreakPoint(CaretY);
end;

procedure TCESynMemo.removeCurLineBreakPoint;
begin
  if findBreakPoint(CaretY) then
    removeBreakPoint(CaretY);
end;

procedure TCESynMemo.toggleCurLineBreakpoint;
begin
  if not findBreakPoint(CaretY) then
    addBreakPoint(CaretY)
  else
    removeBreakPoint(CaretY);
end;

procedure TCESynMemo.insertDdocTemplate;
var
  d: TStringList;
  i: integer;
  j: integer;
  k: integer;
  s: string;
  p: TPoint;
begin
  d := TStringList.Create;
  try
    getDdocTemplate(Strings.TextString_UTF8, d, CaretY, fInsertPlusDdoc);
    if d.Text.isNotEmpty then
    begin
      strings.BeginUndoGroup;
      DoCommand(cCommand_KeyHome);
      k := CaretX;
      p.y:= CaretY -1 ;
      p.x:= 0 ;

      caretXY := p ;
      //ExecuteCommand(ecGotoXY, #0, @p);

      for i := 0 to d.Count-1 do
      begin
        s := d[i];
        DoCommand(cCommand_KeyEnter);
        caretX := 1;
        while caretX < k do
          DoCommand(cCommand_KeyTab);
        DoCommand(cCommand_TextInsert, s);
      end;
      strings.EndUndoGroup;
    end;
  finally
    d.Free;
  end;
end;
{$ENDREGION}

{$REGION DDoc & CallTip --------------------------------------------------------}
procedure TCESynMemo.InitHintWins;
begin
  if fCallTipWin.isNil then
  begin
    fCallTipWin := TCEEditorHintWindow.Create(self);
    fCallTipWin.Color := clInfoBk + $01010100;
    fCallTipWin.Font.Color:= clInfoText;
  end;
  if fDDocWin.isNil then
  begin
    fDDocWin := TCEEditorHintWindow.Create(self);
    fDDocWin.Color := clInfoBk + $01010100;
    fDDocWin.Font.Color:= clInfoText;
  end;
end;

procedure TCESynMemo.showCallTips(findOpenParen: boolean = true);
var
  str, lne: string;
  i, x: integer;
begin
  if not fIsDSource and not alwaysAdvancedFeatures then
    exit;
  if not fCallTipWin.Visible then
    fCallTipStrings.Clear;
  str := lineTextAtCarret[1..CaretX];
  x := CaretX;
  i := x;
  if findOpenParen then while true do
  begin
    if i = 1 then
      break;
    if str[i-1] = '(' then
    begin
      caretXY := Point(i, CaretY);
      break;
    end;
    if str[i] = #9 then
      i -= self.OptTabSize
    else
      i -= 1;
  end;
  DcdWrapper.getCallTip(str);
  begin
    i := fCallTipStrings.Count;
    if (fCallTipStrings.Count <> 0) and str.isNotEmpty then
      fCallTipStrings.Insert(0, '---');
    fCallTipStrings.Insert(0, str);
    i := fCallTipStrings.Count - i;
    // overload count to delete on ')'
    {$PUSH}{$HINTS OFF}{$WARNINGS OFF}
    fCallTipStrings.Objects[0] := TObject(pointer(i));
    {$POP}
    str := '';
    for lne in fCallTipStrings do
      if lne.isNotEmpty then
        str += lne + LineEnding;
    if str.isEmpty then
      exit;
    {$IFDEF WINDOWS}
    str := str[1..str.length-2];
    {$ELSE}
    str := str[1..str.length-1];
    {$ENDIF}
    showCallTips(str);
  end;
  if findOpenParen then
    CaretX:=x;
end;

procedure TCESynMemo.showCallTips(const tips: string);
var
  p: TPoint;
begin
  if (not fIsDSource and not alwaysAdvancedFeatures) or tips.isEmpty then
    exit;

  p := ClientToScreen(point(Carets[0].CoordX, Carets[0].CoordY));
  fCallTipWin.FontSize := Font.Size;
  fCallTipWin.HintRect := fCallTipWin.CalcHintRect(0, tips, nil);
  fCallTipWin.OffsetHintRect(p, Font.Size * 2);
  fCallTipWin.ActivateHint(tips);
end;

procedure TCESynMemo.hideCallTips;
begin
  fCallTipStrings.Clear;
  fCallTipWin.Hide;
end;

procedure TCESynMemo.decCallTipsLvl;
var
  i: integer;
begin
  {$PUSH}{$HINTS OFF}{$WARNINGS OFF}
  i := integer(pointer(fCallTipStrings.Objects[0]));
  {$POP}
  for i in [0..i-1] do
    fCallTipStrings.Delete(0);
  if fCallTipStrings.Count = 0 then
    hideCallTips
  else
    showCallTips(fCallTipStrings.Text);
end;

procedure TCESynMemo.showDDocs;
var
  str: string;
begin
  fCanShowHint := false;
  if not fIsDSource and not alwaysAdvancedFeatures then
    exit;
  DcdWrapper.getDdocFromCursor(str);

  if str.isNotEmpty then
  begin
    fDDocWin.FontSize := Font.Size;
    fDDocWin.HintRect := fDDocWin.CalcHintRect(0, str, nil);
    fDDocWin.OffsetHintRect(mouse.CursorPos, Font.Size);
    fDDocWin.ActivateHint(fDDocWin.HintRect, str);
  end;
end;

procedure TCESynMemo.hideDDocs;
begin
  fCanShowHint := false;
  fDDocWin.Hide;
end;

procedure TCESynMemo.setDDocDelay(value: Integer);
begin
  fDDocDelay:=value;
  fDDocTimer.Interval:=fDDocDelay;
end;

procedure TCESynMemo.DDocTimerEvent(sender: TObject);
begin
  if (not Visible) or (not isDSource) or (not fCanShowHint) then
    exit;

  showDDocs;
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION Completion ------------------------------------------------------------}
procedure TCESynMemo.completionExecute(sender: TObject);
begin
  if not fIsDSource and not alwaysAdvancedFeatures then
    exit;
  fCompletion.TheForm.Font.Size := Font.Size;
  fCompletion.TheForm.BackgroundColor:= self.Color;
  fCompletion.TheForm.TextColor:= fD2Highlighter.identifiers.Foreground;
  getCompletionList;
end;

procedure TCESynMemo.completionDeleteKey(sender: TObject);
begin
  if fCompletionMenuAutoClose and (fCompletion.CurrentString.length < 2) then
    fCompletion.TheForm.Close;
end;

procedure TCESynMemo.getCompletionList;
var
  i: integer;
  o: TObject;
begin
  if not DcdWrapper.available then
    exit;

  fCompletion.Position := 0;
  fCompletion.ItemList.Clear;
  DcdWrapper.getComplAtCursor(TStringList(fCompletion.ItemList));
  if fLastCompletion.isNotEmpty then
  begin
    i := fCompletion.ItemList.IndexOf(fLastCompletion);
    if i <> -1 then
    begin
      o := fCompletion.ItemList.Objects[i];
      fCompletion.ItemList.Delete(i);
      fCompletion.ItemList.InsertObject(0, fLastCompletion, o);
    end
    else fLastCompletion:= '';
  end;
end;

procedure TCESynMemo.completionCodeCompletion(var value: string;
  SourceValue: string; var SourceStart, SourceEnd: TPoint; KeyChar: TUTF8Char;
  Shift: TShiftState);
begin
  if KeyChar <> '' then
  begin
    if KeyChar[1] = ' ' then
      value := sourceValue + KeyChar[1]
    else
    begin
      fLastCompletion := value;
      if KeyChar[1] in fCloseCompletionCharsWithSpace then
        value += ' ' + KeyChar[1]
      else if KeyChar[1] in fCloseCompletionChars then
        value += KeyChar[1];
    end;
  end;
end;

procedure TCESynMemo.completionFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if char(key) = #9 then
    key := 13;
end;

function TCESynMemo.completionItemPaint(const AKey: string; ACanvas: TCanvas;X, Y: integer;
  Selected: boolean; Index: integer): boolean;
var
  dck: TDCDCompletionKind;
  knd: string;
  len: Integer;
begin
  result := true;
  // empty items can be produced if completion list is too long
  if aKey.isEmpty then
    exit;
  {$PUSH} {$Warnings OFF} {$Hints OFF}
  dck := TDCDCompletionKind(PtrUInt(fCompletion.ItemList.Objects[index]));
  knd := DcdCompletionKindStrings[dck];
  {$POP}
  ACanvas.Font.Style := [fsBold];
  len := ACanvas.TextExtent(aKey).cx;
  ACanvas.TextOut(2 + X , Y, aKey);
  case dck of
    dckALias, dckClass, dckStruct, dckUnion, dckEnum, dckInterface:
      ACanvas.Font.Color:= clMaroon;
    dckMember, dckEnum_member, dckVariable, dckArray, dckAA:
      ACanvas.Font.Color:= clGray;
    dckReserved:
      ACanvas.Font.Color:= clNavy;
    dckFunction:
      ACanvas.Font.Color:= clGreen;
    dckPackage, dckModule:
      ACanvas.Font.Color:= clBlue;
    dckTemplate, dckMixin:
      ACanvas.Font.Color:= clTeal;
  end;
  ACanvas.Font.Style := [fsItalic];
  ACanvas.TextOut(2 + X + len + 2, Y, knd);
end;

procedure TCESynMemo.AutoDotTimerEvent(sender: TObject);
begin
  if (not fCanAutoDot) or (fAutoDotDelay = 0) then
    exit;

  fCanAutoDot := false;
  //fCompletion.Execute('', ClientToScreen(point(CaretXPix, CaretYPix + LineHeight)));
end;

procedure TCESynMemo.setAutoDotDelay(value: Integer);
begin
  fAutoDotDelay:=value;
  fAutoDotTimer.Interval:=fAutoDotDelay;
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION Dscanner --------------------------------------------------------------}
constructor TDscannerResults.create;
begin
  fList := TFPList.Create;
end;

destructor TDscannerResults.destroy;
begin
  clear;
  fList.Free;
  inherited;
end;

procedure TDscannerResults.clear;
var
  i: integer;
begin
  for i:= 0 to fList.Count-1 do
    dispose(PDscannerResult(fList[i]));
  fList.Clear;
end;

procedure TDscannerResults.push(const warning: string; line, column: integer);
var
  r: PDscannerResult;
begin
  r := new(PDscannerResult);
  r^.column:=column;
  r^.warning:=warning;
  r^.line:=line;
  fList.Add(r);
end;

function TDscannerResults.getCount: integer;
begin
  result := fList.Count;
end;

function TDscannerResults.getItem(index: integer): PDscannerResult;
begin
  result := PDscannerResult(fList[index]);
end;

procedure TCESynMemo.setDscannerOptions(dsEnabled: boolean; dsDelay: integer);
begin
  fDscannerTimer.Interval:=dsDelay;
  fDscannerEnabled := dsEnabled;
  if not dsEnabled then
    removeDscannerWarnings
  else
    dscannerTimerEvent(nil);
end;

procedure TCESynMemo.dscannerTimerEvent(sender: TObject);
var
  s: string;
begin
  if not fDscannerEnabled or not fKnowsDscanner or not isDSource
    or not fCanDscan then
      exit;

  removeDscannerWarnings;
  fCanDscan := false;
  fDScanner.execute;
  s := Strings.TextString_UTF8;
  if s.length > 0 then
    fDscanner.Input.Write(s[1], s.length);
  fDscanner.CloseInput;
end;

procedure TCESynMemo.dscannerTerminate(sender: TObject);
  procedure processLine(const lne: string);
  var
    r: TStringRange = (ptr:nil; pos:0; len: 0);
    line: integer;
    column: integer;
  begin
    if lne.isBlank then
      exit;
    r.init(lne);
    line := r.popUntil('(')^.popFront^.takeWhile(['0'..'9']).yield.toIntNoExcept();
    column := r.popFront^.takeWhile(['0'..'9']).yield.toIntNoExcept();
    r.popUntil(':');
    r.popFront;
    fDscannerResults.push(r.takeUntil(#0).yield, line, column);

    addGutterIcon(line, giWarn);

  end;
var
  i: integer;
  s: string;
  m: TStringList;
begin
  m := TStringList.Create;
  try
    fDscanner.getFullLines(m);
    for i := 0 to m.Count-1 do
    begin
      s := m[i];
      processLine(s);
    end;
  finally
    m.free;
  end;
end;

procedure TCESynMemo.removeDscannerWarnings;
var
  i: integer;
  n: TSynEditMark;
begin
  //IncPaintLock;
  fDscannerResults.clear;
  //for i:= Marks.Count-1 downto 0 do
  //  if marks.Items[i].ImageIndex = longint(giWarn) then
  //begin
  //  n := marks.Items[i];
  //  marks.Delete(i);
  //  FreeAndNil(n);
  //end;
  //DecPaintLock;
  //repaint;
end;

function TCESynMemo.getDscannerWarning(line: integer): string;
const
  spec = '@column %d: %s' + LineEnding;
var
  i: integer;
begin
  result := '';
  for i := 0 to fDscannerResults.count-1 do
    if fDscannerResults[i]^.line = line then
      result += format(spec, [fDscannerResults[i]^.column, fDscannerResults[i]^.warning]);
end;

function TCESynMemo.lineHasDscannerWarning(line: integer): boolean;
var
  i: integer;
begin
  result := false;
  for i := 0 to fDscannerResults.count-1 do
    if fDscannerResults[i]^.line = line then
      exit(true);
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION Coedit memo things ----------------------------------------------------}
procedure TCESynMemo.handleStatusChanged(Sender: TObject; Changes: TSynStatusChanges);
begin
  //if scOptions in Changes then
  //begin
  //  if fSmartDdocNewline and not (eoAutoIndent in Options) then
  //    Options := Options + [eoAutoIndent];
  //  if Beautifier.isNotNil and (Beautifier is TSynBeautifier) then
  //  begin
  //    if not (eoTabsToSpaces in Options) and not (eoSpacesToTabs in Options) then
  //      TSynBeautifier(Beautifier).IndentType := sbitConvertToTabOnly
  //    else if eoSpacesToTabs in options then
  //      TSynBeautifier(Beautifier).IndentType := sbitConvertToTabOnly
  //    else
  //      TSynBeautifier(Beautifier).IndentType := sbitSpace;
  //  end;
  //end;
end;

function TCESynMemo.pageCaption(checkModule: boolean): string;
begin
  result := '';
  fHasModuleDeclaration := false;
  if checkModule and isDSource then
  begin
    fLexToks.Clear;
    lex(Strings.TextString_UTF8, fLexToks, @tokFoundForCaption, [lxoNoComments]);
    if fHasModuleDeclaration then
      result := getModuleName(fLexToks);
  end;
  if result.length = 0 then
  begin
    if fFilename.length > 0 then
      result := fFilename.extractFileName
    else
      result := '<new document>';
  end;
end;

procedure TCESynMemo.tokFoundForCaption(const token: PLexToken; out stop: boolean);
begin
  if token^.kind = ltkKeyword then
  begin
    if token^.data = 'module' then
      fModuleTokFound := true
    else
      // "module" is always the first KW
      stop := true;
  end
  else if fModuleTokFound and (token^.kind = ltkSymbol) and (token^.data = ';') then
  begin
    stop := true;
    fModuleTokFound := false;
    fHasModuleDeclaration := true;
  end;
end;

function TCESynMemo.lexInDdoc: char;
var
  i: integer;
  p: integer;
  tk1: PLexToken = nil;
  tk2: PLexToken = nil;
  r: TStringRange = (ptr:nil; pos:0; len: 0);
begin
  result := #0;
  p := caretBytePosition;
  for i := 0 to fLexToks.Count-1 do
  begin
    tk1 := fLexToks[i];
    if (i <> fLexToks.Count-1) then
    begin
      tk2 := fLexToks[i+1];
      if (tk1^.offset < p) and (tk1^.kind in [ltkComment, ltkIllegal])
        and (tk1^.Data[1] in ['*','+']) and (tk2^.offset > p) then
      begin
        r.init(tk1^.Data);
        r.popUntil(#10)^.popFront;
        if not r.empty then
          r.popWhile([' ', #9]);
        if not r.empty then
        begin
          if r.front in ['*','+'] then
            exit(r.front)
          else
            exit(#0);
        end
        else exit(tk1^.Data[1])
      end
      else if (tk1^.offset > p) then
        exit;
    end
    else if (tk1^.offset < p) and (tk1^.kind in [ltkComment, ltkIllegal])
      and (tk1^.Data[1] in ['*','+']) then
        exit(tk1^.Data[1]);
  end;
end;

function TCESynMemo.lexCanCloseBrace: boolean;
var
  i: integer;
  p: integer;
  c: integer = 0;
  tok: PLexToken = nil;
  ton: PLexToken = nil;
  bet: boolean;
begin
  p := caretBytePosition;
  for i := 0 to fLexToks.Count-1 do
  begin
    tok := fLexToks[i];
    if (i <> fLexToks.Count-1) then
    begin
      ton := fLexToks[i+1];
      bet := (tok^.offset + 1 <= p) and (p < ton^.offset + 2);
    end
    else bet := false;
    if bet and (tok^.kind = ltkComment) then
      exit(false);
    c += byte((tok^.kind = TLexTokenKind.ltkSymbol) and (((tok^.Data = '{')) or (tok^.Data = 'q{')));
    c -= byte((tok^.kind = TLexTokenKind.ltkSymbol) and (tok^.Data = '}'));
    if bet and (c = 0) then
      exit(false);
  end;
  if (tok <> nil) and (tok^.kind = ltkIllegal) then
    result := false
  else
    result := c > 0;
end;

procedure TCESynMemo.SetHighlighter(const Value: TSynCustomHighlighter);
begin
  inherited;
  //fIsDSource := Highlighter = fD2Highlighter;
  //fIsTxtFile := Highlighter = fTxtHighlighter;
end;

procedure TCESynMemo.highlightCurrentIdentifier;
var
  str: string;
  i: integer;
begin
  //fIdentifier := GetWordAtRowCol(LogicalCaretXY);
  //if (fIdentifier.length > 2) and (not SelAvail) then
  //  SetHighlightSearch(fIdentifier, fMatchIdentOpts)
  //else if SelAvail and (BlockBegin.Y = BlockEnd.Y) then
  //begin
  //  str := SelText;
  //  for i := 1 to str.length do
  //  begin
  //    if not (str[i] in [' ', #10, #13]) then
  //    begin
  //      SetHighlightSearch(str, fMatchSelectionOpts);
  //      break;
  //    end;
  //    if i = str.length then
  //      SetHighlightSearch('', []);
  //  end;
  //end
  //else SetHighlightSearch('', []);
end;

procedure TCESynMemo.setMatchOpts(value: TIdentifierMatchOptions);
begin
  fMatchOpts:= value;
  fMatchIdentOpts := TSynSearchOptions(fMatchOpts);
  fMatchSelectionOpts:= TSynSearchOptions(fMatchOpts - [wholeWord]);
end;

procedure TCESynMemo.changeNotify(Sender: TObject);
begin
  highlightCurrentIdentifier;
  subjDocChanged(TCEMultiDocSubject(fMultiDocSubject), self);
end;

procedure TCESynMemo.loadFromFile(const fname: string);
var
  ext: string;
  imd: TIndentationMode;
begin
  ext := fname.extractFileExt;
  fIsDsource := hasDlangSyntax(ext);
  //if not fIsDsource then
  //  Highlighter := TxtSyn;
  inherited LoadFromFile(fname);
  fFilename := fname;
  FileAge(fFilename, fFileDate);
  ModeReadOnly := FileIsReadOnly(fFilename);

  modified := false;
  if Showing then
  begin
    setFocus;
    loadCache;
    fCacheLoaded := true;
  end;
  if detectIndentMode then
  begin
    imd := indentationMode();
    case imd of
      imTabs: OptTabSpaces:= false;
      imSpaces: OptTabSpaces:= true;
      // TODO: ask for conversion if result is imMixed
      imMixed: begin end;
    end;
  end;
  subjDocChanged(TCEMultiDocSubject(fMultiDocSubject), self);
  fCanDscan := true;
end;

procedure TCESynMemo.saveToFile(const fname: string);
var
  ext: string;
begin
  ext := fname.extractFilePath;
  if FileIsReadOnly(ext) then
  begin
    getMessageDisplay.message('No write access in: ' + ext, self, amcEdit, amkWarn);
    exit;
  end;
  ModeReadOnly := false;
  inherited SaveToFile(fname);
  fFilename := fname;
  ext := fname.extractFileExt;
  fIsDsource := hasDlangSyntax(ext);
  //if fIsDsource then
  //  Highlighter := fD2Highlighter
  //else if not isProjectDescription then
  //  Highlighter := TxtHighlighter;
  FileAge(fFilename, fFileDate);
  modified := false;
  if fFilename <> fTempFileName then
  begin
    if fTempFileName.fileExists then
      sysutils.DeleteFile(fTempFileName);
    subjDocChanged(TCEMultiDocSubject(fMultiDocSubject), self);
  end;
end;

procedure TCESynMemo.save;
begin
  if ModeReadOnly then
    exit;
  inherited saveToFile(fFilename);
  FileAge(fFilename, fFileDate);
  modified := false;
  if fFilename <> fTempFileName then
    subjDocChanged(TCEMultiDocSubject(fMultiDocSubject), self);
end;

procedure TCESynMemo.saveTempFile;
begin
  saveToFile(fTempFileName);
  modified := false;
end;

function TCESynMemo.getIfTemp: boolean;
begin
  exit(fFilename = fTempFileName);
end;

procedure TCESynMemo.saveCache;
var
  cache: TCESynMemoCache;
begin
  cache := TCESynMemoCache.create(self);
  try
    cache.save;
  finally
    cache.free;
  end;
end;

procedure TCESynMemo.loadCache;
var
  cache: TCESynMemoCache;
begin
  cache := TCESynMemoCache.create(self);
  try
    cache.load;
  finally
    cache.free;
  end;
end;

class procedure TCESynMemo.cleanCache;
var
  lst: TStringList;
  today, t: TDateTime;
  fname: string;
  y, m, d: word;
begin
  lst := TStringList.Create;
  try
    listFiles(lst, getCoeditDocPath + 'editorcache' + DirectorySeparator);
    today := date();
    for fname in lst do if FileAge(fname, t) then
    begin
      DecodeDate(t, y, m, d);
      IncAMonth(y, m, d, 3);
      if EncodeDate(y, m, d) <= today then
        sysutils.DeleteFile(fname);
    end;
  finally
    lst.free;
  end;
end;

procedure TCESynMemo.replaceUndoableContent(const value: string);
var
  b: TPoint;
  e: TPoint;
  p: TPoint;
begin
  //p := CaretXY;
  //b := point(1,1);
  //e := Point(length(Lines[lines.Count-1])+1,lines.Count);
  //TextBetweenPoints[b,e] := value;
  //CaretXY := p;
  //EnsureCursorPosVisible;
  //modified := true;
end;

procedure TCESynMemo.checkFileDate;
var
  mr: TModalResult;
  newDate: double;
  newMd5: TMDDigest;
  curMd5: TMDDigest;
  str: TStringList;
  txt: string;
begin
  //if fDiffDialogWillClose or fDisableFileDateCheck then
  //  exit;
  //if fFilename.isNotEmpty and not fFilename.fileExists and
  //  (fFilename <> '<new document>') then
  //begin
  //  // cant use a dialog: dialog closed -> doc focused -> warn again, etc
  //  getMessageDisplay.message(fFilename + ' does not exist anymore', self, amcEdit, amkWarn);
  //end;
  //if (fFilename = fTempFileName) or fDisableFileDateCheck
  //  or not FileAge(fFilename, newDate) or (fFileDate = newDate) then
  //    exit;
  //if (fFileDate <> 0.0) then
  //begin
  //  str := TStringList.Create;
  //  try
  //    str.LoadFromFile(fFilename);
  //    txt := str.strictText;
  //    newMd5 := MD5String(txt);
  //    txt := lines.strictText;
  //    curMd5 := MD5String(txt);
  //    if not MDMatch(curMd5, newMd5) then
  //    begin
  //      lines.SaveToFile(tempFilename);
  //      fDiffDialogWillClose := true;
  //      With TCEDiffViewer.construct(self, fTempFileName, fFilename) do
  //      try
  //        mr := ShowModal;
  //        case mr of
  //          mrOK:
  //          begin
  //            replaceUndoableContent(str.strictText);
  //            fFileDate := newDate;
  //          end;
  //          mrIgnore: fFileDate := newDate;
  //          mrCancel:;
  //        end;
  //      finally
  //        free;
  //        fDiffDialogWillClose := false;
  //      end;
  //    end;
  //  finally
  //    str.Free;
  //  end;
  //end
  //else fFileDate := newDate;
end;

function TCESynMemo.getMouseBytePosition: Integer;
var
  x: integer;
  y: integer;
  i: integer;
begin
  result := 0;
  x := fMousePos.x;
  y := fMousePos.y;
  if (x - 1 > strings.LinesLen[y]) or (y > Strings.Count-1) then
    exit;
  for i:= 0 to y-1 do
    result += Strings.LinesLenPhysical[i];
  result += x;
end;

procedure TCESynMemo.patchClipboardIndentation;
var
  lst: TStringList;
  lne: string;
  i: integer;
begin
  ////TODO: Check for changes made to option eoSpacesToTabs
  //if not (eoTabsToSpaces in Options) then
  //  exit;
  //
  //lst := TStringList.Create;
  //lst.Text:=clipboard.asText;
  //try
  //  for i := 0 to lst.count-1 do
  //  begin
  //    lne := lst[i];
  //    //if eoTabsToSpaces in Options then
  //    //begin
  //      leadingTabsToSpaces(lne, TabWidth);
  //      lst[i] := lne;
  //    //end
  //    {else if eoSpacesToTabs in Options then
  //    begin
  //      //leadingSpacesToTabs(lne, TabWidth);
  //      //lst[i] := lne;
  //    end}
  //  end;
  //  clipboard.asText := lst.strictText;
  //finally
  //  lst.free;
  //end;
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION user input ------------------------------------------------------------}
procedure TCESynMemo.KeyDown(var Key: Word; Shift: TShiftState);
var
  line: string;
  ddc: char;
  lxd: boolean;
  i, j: integer;
begin
  case Key of
    VK_BACK:
    begin
      fCanDscan:=true;
      if fCallTipWin.Visible and (CaretX > 1)
        and (lineTextAtCarret()[caretX-1] = '(') then
          decCallTipsLvl;
    end;
    VK_RETURN:
    begin
      fCanDscan:=true;
      line := lineTextAtCarret;
      case fAutoCloseCurlyBrace of
        autoCloseOnNewLineAlways: if (CaretX > 1) and (line[caretX - 1] = '{') then
        begin
          Key := 0;
          curlyBraceCloseAndIndent;
        end;
        autoCloseOnNewLineEof: if (CaretX > 1) and (line[caretX - 1] = '{') then
        if (CaretY = Strings.Count) and (CaretX = line.length+1) then
        begin
          Key := 0;
          curlyBraceCloseAndIndent;
        end;
      end;

      if (fAutoCloseCurlyBrace = autoCloseOnNewLineLexically) or
        fSmartDdocNewline then
      begin
        lxd := false;
        i := caretX;
        j := line.length;
        if (i - 1 >= j) or isBlank(line[caretX .. line.length]) then
        begin
          lxd := true;
          fLexToks.Clear;
          lex(Strings.TextString_UTF8, fLexToks);
          if lexCanCloseBrace then
          begin
            Key := 0;
            curlyBraceCloseAndIndent;
            lxd := false;
          end;
        end;
        if (fSmartDdocNewline) then
        begin
          if not lxd then
          begin
            fLexToks.Clear;
            lex(Strings.TextString_UTF8, fLexToks);
          end;
          ddc := lexInDdoc;
          if ddc in ['*', '+'] then
          begin
            inherited;
            insertLeadingDDocSymbol(ddc);
            fCanShowHint:=false;
            fDDocWin.Hide;
            exit;
          end;
        end;
      end;
    end;
  end;
  inherited;
  //highlightCurrentIdentifier;
  //if fCompletion.IsActive then
  //  fCompletion.CurrentString:= GetWordAtRowCol(LogicalCaretXY);
  case Key of
    VK_BROWSER_BACK: fPositions.back;
    VK_BROWSER_FORWARD: fPositions.next;
    VK_ESCAPE:
      begin
        hideCallTips;
        hideDDocs;
      end;
  end;
  if not (Shift = [ssCtrl]) then exit;
  case Key of
    VK_ADD: if Font.Size < 50 then Font.Size := Font.Size + 1;
    VK_SUBTRACT: if Font.Size > 3 then Font.Size := Font.Size - 1;
    VK_DECIMAL: Font.Size := fDefaultFontSize;
  end;
  fCanShowHint:=false;
  fDDocWin.Hide;
end;

procedure TCESynMemo.KeyUp(var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_PRIOR, VK_NEXT, VK_UP: fPositions.store;
    VK_OEM_PERIOD, VK_DECIMAL: fCanAutoDot := true;
  end;
  inherited;
  //if fAutoCallCompletion and fIsDSource and (not fCompletion.IsActive) and
  //  (Key < $80) and (char(Key) in ['a'..'z', 'A'..'Z']) then
  //begin
  //  fCompletion.Execute(GetWordAtRowCol(LogicalCaretXY),
  //    ClientToScreen(point(CaretXPix, CaretYPix + LineHeight)));
  //end;
  //if StaticEditorMacro.automatic then
  //  StaticEditorMacro.Execute;
end;

procedure TCESynMemo.UTF8KeyPress(var Key: TUTF8Char);
var
  c: AnsiChar;
begin
  c := Key[1];
  inherited;
  fCanDscan := true;
  case c of
    #39: if autoCloseSingleQuote in fAutoClosedPairs then
      autoClosePair(autoCloseSingleQuote);
    '"': if autoCloseDoubleQuote in fAutoClosedPairs then
      autoClosePair(autoCloseDoubleQuote);
    '`': if autoCloseBackTick in fAutoClosedPairs then
      autoClosePair(autoCloseBackTick);
    '[': if autoCloseSquareBracket in fAutoClosedPairs then
      autoClosePair(autoCloseSquareBracket);
    '(': showCallTips(false);
    ')': if fCallTipWin.Visible then decCallTipsLvl;
    '{':
        case fAutoCloseCurlyBrace of
          autoCloseAlways:
            curlyBraceCloseAndIndent;
          autoCloseAtEof:
            if (CaretY = Strings.Count) and (CaretX = lineTextAtCarret.length+1) then
              curlyBraceCloseAndIndent;
          autoCloseLexically:
          begin
            fLexToks.Clear;
            lex(Strings.TextString_UTF8, fLexToks);
            if lexCanCloseBrace then
              curlyBraceCloseAndIndent;
          end;
        end;
  end;
  //if fCompletion.IsActive then
  //  fCompletion.CurrentString:=GetWordAtRowCol(LogicalCaretXY);
end;

procedure TCESynMemo.MouseLeave;
begin
  inherited;
  hideDDocs;
  hideCallTips;
  fScrollMemo.Visible:=false;
end;

procedure TCESynMemo.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  dx, dy: Integer;
  dt: TATPosDetails;
begin
  hideDDocs;
  hideCallTips;
  inherited;
  dx := X - fOldMousePos.x;
  dy := Y - fOldMousePos.y;
  fCanShowHint:=false;
  if (shift = []) then if
    ((dx < 0) and (dx > -5) or (dx > 0) and (dx < 5)) or
      ((dy < 0) and (dy > -5) or (dy > 0) and (dy < 5)) then
        fCanShowHint:=true;
  fOldMousePos := Point(X, Y);
  fMousePos := ClientPosToCaretPos(fOldMousePos, dt);

  //if ssLeft in Shift then
  //  highlightCurrentIdentifier;
  //
  //if fScrollPreview then
  //begin
  //  if (x > width - 40) and (x < width - 20) then
  //  begin;
  //    fScrollMemo.Visible:=true;
  //    fScrollMemo.goToLine(trunc((lines.Count / Height) * Y));
  //    fScrollMemo.left := width - 40 - fScrollMemo.Width;
  //    fScrollMemo.Top:= Y - 5;
  //  end
  //  else
  //  begin
  //    fScrollMemo.Visible:=false;
  //  end;
  //end;

end;

procedure TCESynMemo.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y:Integer);
begin
  inherited;
  highlightCurrentIdentifier;
  fCanShowHint := false;
  hideCallTips;
  hideDDocs;
  //if (emAltSetsColumnMode in MouseOptions) and not (eoScrollPastEol in Options)
  //  and (ssLeft in shift) and (ssAlt in Shift) then
  //begin
  //  fOverrideColMode := true;
  //  Options := Options + [eoScrollPastEol];
  //end;
end;

procedure TCESynMemo.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y:Integer);
var
  pt: TPoint;
begin
  inherited;
  if fScrollPreview and fScrollMemo.Visible and (button = mbLeft) then
  begin
    pt := Mouse.CursorPos;
    pt.x:= pt.x - 40;
    //CaretY := fScrollMemo.fMemo.CaretY;
    //EnsureCursorPosVisible;
    fScrollMemo.Visible:=false;
    mouse.CursorPos := pt;
    fPositions.store;
  end;
  case Button of
    mbMiddle: if (Shift = [ssCtrl]) then
      Font.Size := fDefaultFontSize;
    mbExtra1: fPositions.back;
    mbExtra2: fPositions.next;
    mbLeft:   fPositions.store;
  end;
  //if fOverrideColMode and not SelAvail then
  //begin
  //  fOverrideColMode := false;
  //  Options := Options - [eoScrollPastEol];
  //end;
end;

function TCESynMemo.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
  fCanShowHint:=false;
  fDDocTimer.Enabled:=false;
end;
{$ENDREGION --------------------------------------------------------------------}

{$REGION debugging/breakpoints -----------------------------------------------------------}
function TCESynMemo.breakPointsCount: integer;
var
  i: integer;
begin
  result := 0;
  //for i := 0 to marks.count-1 do
  //  result += byte(marks[i].ImageIndex = integer(giBreakSet));
end;

procedure TCESynMemo.addBreakPoint(line: integer);
begin
  if findBreakPoint(line) then
    exit;
  addGutterIcon(line, giBreakSet);
  if assigned(fDebugger) then
    fDebugger.addBreakPoint(fFilename, line, bpkBreak);
end;

procedure TCESynMemo.removeBreakPoint(line: integer);
var
  break2step: boolean;
begin
  if not findBreakPoint(line) then
    exit;
  break2step := isGutterIconSet(line, giBreakReached);
  removeGutterIcon(line, giBreakSet);
  if fDscannerEnabled and lineHasDscannerWarning(line) then
    addGutterIcon(line, giWarn);
  if assigned(fDebugger) then
  begin
    fDebugger.removeBreakPoint(fFilename, line);
    if break2step and fDebugger.running then
      addGutterIcon(line, giStep);
  end;
end;

procedure TCESynMemo.showHintEvent(Sender: TObject; HintInfo: PHintInfo);
var
  p: TPoint;
  d: TATPosDetails;
begin
  //if cursor <> crDefault then
  //  exit;
  p := ScreenToClient(mouse.CursorPos);
  if p.x > Gutter.Width then
    exit;
  p := self.ClientPosToCaretPos(p, d);
  showWarningForLine(p.y + 1);
end;

procedure TCESynMemo.removeDebugTimeMarks;
var
  i: integer;
begin
  //IncPaintLock;
  //for i:= marks.Count-1 downto 0 do
  //  Marks.Items[i].Visible := not (TGutterIcon(Marks.Items[i].ImageIndex) in debugTimeGutterIcons);
  //DecPaintLock;
end;

function TCESynMemo.isGutterIconSet(line: integer; value: TGutterIcon): boolean;
var
  m: TSynEditMarkLine = nil;
  i: integer;
begin
  //result := false;
  //if line <= lines.count then
  //  m := marks.Line[line];
  //if m.isNotNil then
  //  for i := 0 to m.count - 1 do
  //    if (m[i].ImageIndex = integer(value)) then
  //      exit(true);
end;

function TCESynMemo.findBreakPoint(line: integer): boolean;
begin
  result := isGutterIconSet(line, giBreakSet);
end;

procedure TCESynMemo.gutterClick(Sender: TObject; X, Y, Line: integer; mark: TSynEditMark);
begin
  //if findBreakPoint(line) then
  //  removeBreakPoint(line)
  //else
  //  addBreakPoint(line);
  //CaretY := Line;
  //EnsureCursorPosVisible;
end;

procedure TCESynMemo.addGutterIcon(line: integer; value: TGutterIcon);
var
  m: TSynEditMarkLine;
  n: TSynEditMark;
  i: integer;
  s: boolean = false;
begin
  //m := Marks.Line[line];
  //if m.isNotNil then
  //  for i := 0 to m.Count-1 do
  //begin
  //  s := m.Items[i].ImageIndex = longint(value);
  //  m.Items[i].Visible := s;
  //end;
  //if not s then
  //begin
  //  n:= TSynEditMark.Create(self);
  //  n.Line := line;
  //  n.ImageList := fImages;
  //  n.ImageIndex := longint(value);
  //  n.Visible := true;
  //  Marks.Add(n);
  //end;
end;

procedure TCESynMemo.removeGutterIcon(line: integer; value: TGutterIcon);
var
  m: TSynEditMarkLine;
  n: TSynEditMark;
  i: integer;
begin
  //m := Marks.Line[line];
  //if m.isNotNil then
  //  for i := m.Count-1 downto 0 do
  //begin
  //  n := m.Items[i];
  //  if n.ImageIndex = longint(value) then
  //  begin
  //    m.Delete(i);
  //    FreeAndNil(n);
  //  end;
  //end;
  //Repaint;
end;

procedure TCESynMemo.debugStart(debugger: ICEDebugger);
var
  i: integer;
  m: TSynEditMark;
begin
  fDebugger := debugger;
  fDebugger.removeBreakPoints(fileName);
  //for i := 0 to marks.count - 1 do
  //begin
  //  m := marks[i];
  //  if m.ImageIndex = integer(giBreakSet) then
  //    fDebugger.addBreakPoint(filename, m.line, bpkBreak);
  //end;
end;

procedure TCESynMemo.debugStop;
begin
  removeDebugTimeMarks;
end;

procedure TCESynMemo.debugContinue;
begin
  removeDebugTimeMarks;
end;

function TCESynMemo.debugQueryBpCount: integer;
begin
  exit(breakPointsCount());
end;

procedure TCESynMemo.debugQueryBreakPoint(const line: integer; out fname: string; out kind: TBreakPointKind);
begin
  if findBreakPoint(line) then
  begin
    fname:= fFilename;
    kind := bpkBreak;
  end
  else kind := bpkNone;
end;

procedure TCESynMemo.debugBreak(const fname: string; line: integer;
  reason: TCEDebugBreakReason);
begin
  //if fname <> fFilename then
  //  exit;
  //showPage;
  //caretY := line;
  //EnsureCursorPosVisible;
  //removeDebugTimeMarks;
  //removeDscannerWarnings;
  //case reason of
  //  dbBreakPoint: addGutterIcon(line, giBreakReached);
  //  dbStep, dbSignal: addGutterIcon(line, giStep);
  //  dbWatch: addGutterIcon(line, giWatch);
  //end;
end;
{$ENDREGION --------------------------------------------------------------------}

{$ENDREGION --------------------------------------------------------------------}

initialization
  D2Syn := TSynD2Syn.create(nil);
  LfmSyn := TSynLFMSyn.Create(nil);
  TxtSyn := TSynTxtSyn.create(nil);
  JsSyn := TSynJScriptSyn.Create(nil);
  //
  LfmSyn.KeyAttri.Foreground := clNavy;
  LfmSyn.KeyAttri.Style := [fsBold];
  LfmSyn.NumberAttri.Foreground := clMaroon;
  LfmSyn.StringAttri.Foreground := clBlue;
  LfmSyn.SymbolAttribute.Foreground:= clPurple;
  LfmSyn.SymbolAttribute.Style := [fsBold];
  //
  JsSyn.KeyAttri.Foreground := clNavy;
  JsSyn.KeyAttri.Style := [fsBold];
  JsSyn.NumberAttri.Foreground := clMaroon;
  JsSyn.StringAttri.Foreground := clBlue;
  JsSyn.SymbolAttribute.Foreground:= clPurple;
  JsSyn.SymbolAttribute.Style := [fsBold];
  //
  TCEEditorHintWindow.FontSize := 10;
  //
  RegisterKeyCmdIdentProcs(@CustomStringToCommand, @CustomCommandToSstring);
finalization
  D2Syn.Free;
  LfmSyn.Free;
  TxtSyn.Free;
  JsSyn.Free;
  //
  TCESynMemo.cleanCache;
end.
