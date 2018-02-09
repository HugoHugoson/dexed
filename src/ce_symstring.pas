unit ce_symstring;

{$I ce_defines.inc}

interface

uses
  ce_observer, sysutils, ce_interfaces, ce_ceproject, ce_synmemo, ce_common,
  ce_stringrange;

type

  (**
   * Enumerates the symbol kinds, used to index an associative array.
   *)
  TCESymbol = ( ENV_USER, ENV_HOME, ENV_TEMP, CAF, CAP,
                CFF, CFP, CFR, CI, CL, CPF, CPP, CPO, CPOP, CPR, CPN, CPFS, CPCD,
                CPV, CS);
const

  FirstVariableSymbol = CFF;

type

  (**
   * TCESymbolExpander is designed to expand Coedit symbolic strings,
   * using the information collected from several observer interfaces.
   *)
  TCESymbolExpander = class(ICEDocumentObserver, ICEProjectObserver, ICESymStringExpander)
  private
    fProj: TCENativeProject;
    fProjInterface: ICECommonProject;
    fDoc: TCESynMemo;
    fNeedUpdate: boolean;
    fSymbols: array[TCESymbol] of string;
    procedure updateSymbols;
    //
    procedure projNew(project: ICECommonProject);
    procedure projClosing(project: ICECommonProject);
    procedure projFocused(project: ICECommonProject);
    procedure projChanged(project: ICECommonProject);
    procedure projCompiling(project: ICECommonProject);
    procedure projCompiled(project: ICECommonProject; success: boolean);
    //
    procedure docNew(document: TCESynMemo);
    procedure docClosing(document: TCESynMemo);
    procedure docFocused(document: TCESynMemo);
    procedure docChanged(document: TCESynMemo);
    //
    function singleServiceName: string;
    function expand(const value: string): string;
  public
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  Forms, Classes;
var
  symbolExpander: TCESymbolExpander;

{$REGION Standard Comp/Obj------------------------------------------------------}
constructor TCESymbolExpander.Create;
begin
  EntitiesConnector.addObserver(self);
  EntitiesConnector.addSingleService(self);
  fNeedUpdate := true;
  //
  {$IFDEF UNIX}
  fSymbols[ENV_USER] := sysutils.GetEnvironmentVariable('USER');
  fSymbols[ENV_HOME] := sysutils.GetEnvironmentVariable('HOME');
  fSymbols[ENV_TEMP] := sysutils.GetEnvironmentVariable('TMPDIR');
  {$ELSE}
  fSymbols[ENV_USER] := sysutils.GetEnvironmentVariable('USERNAME');
  fSymbols[ENV_HOME] := sysutils.GetEnvironmentVariable('HOMEPATH');
  fSymbols[ENV_TEMP] := sysutils.GetEnvironmentVariable('TEMP');
  {$ENDIF}
  fSymbols[CAF] := Application.ExeName;
  fSymbols[CAP] := fSymbols[CAF].extractFilePath;
end;

destructor TCESymbolExpander.Destroy;
begin
  fNeedUpdate := false;
  EntitiesConnector.removeObserver(self);
  inherited;
end;
{$ENDREGION}

{$REGION ICEProjectObserver ----------------------------------------------------}
procedure TCESymbolExpander.projNew(project: ICECommonProject);
begin
  fProjInterface := project;
  case project.getFormat of
    pfCE: fProj := TCENativeProject(project.getProject);
    pfDUB: fProj := nil;
  end;
  fNeedUpdate := true;
end;

procedure TCESymbolExpander.projClosing(project: ICECommonProject);
begin
  fProjInterface := nil;
  if fProj <> project.getProject then
    exit;
  fProj := nil;
  fNeedUpdate := true;
end;

procedure TCESymbolExpander.projFocused(project: ICECommonProject);
begin
  fProjInterface := project;
  case project.getFormat of
    pfCE: fProj := TCENativeProject(project.getProject);
    pfDUB: fProj := nil;
  end;
  fNeedUpdate := true;
end;

procedure TCESymbolExpander.projChanged(project: ICECommonProject);
begin
  fNeedUpdate := true;
end;

procedure TCESymbolExpander.projCompiling(project: ICECommonProject);
begin
end;

procedure TCESymbolExpander.projCompiled(project: ICECommonProject; success: boolean);
begin
end;
{$ENDREGION}

{$REGION ICEDocumentObserver ---------------------------------------------------}
procedure TCESymbolExpander.docNew(document: TCESynMemo);
begin
  fDoc := document;
  fNeedUpdate := true;
end;

procedure TCESymbolExpander.docClosing(document: TCESynMemo);
begin
  if document <> fDoc then
    exit;
  fDoc := nil;
  fNeedUpdate := true;
end;

procedure TCESymbolExpander.docFocused(document: TCESynMemo);
begin
  if (document.isNotNil) and (fDoc = document) then
    exit;
  fDoc := document;
  fNeedUpdate := true;
end;

procedure TCESymbolExpander.docChanged(document: TCESynMemo);
begin
  if document <> fDoc then
    exit;
  fNeedUpdate := true;
end;
{$ENDREGION}

{$REGION Symbol things ---------------------------------------------------------}
procedure TCESymbolExpander.updateSymbols;
var
  hasNativeProj: boolean;
  hasProjItf: boolean;
  hasDoc: boolean;
  fname: string;
  i: Integer;
  e: TCESymbol;
  str: TStringList;
const
  na = '``';
begin
  if not fNeedUpdate then exit;
  fNeedUpdate := false;
  //
  hasNativeProj := fProj.isNotNil;
  hasProjItf := fProjInterface <> nil;
  hasDoc := fDoc.isNotNil;
  //
  for e := FirstVariableSymbol to high(TCESymbol) do
    fSymbols[e] := na;
  // document
  if hasDoc then
  begin
    if not fDoc.fileName.fileExists then
      fDoc.saveTempFile;
    fSymbols[CFF] := fDoc.fileName;
    fSymbols[CFR] := fSymbols[CFF].stripFileExt + exeExt;
    fSymbols[CFP] := fSymbols[CFF].extractFilePath;
    if fDoc.TextCurrentWord <> '' then
      fSymbols[CI] := fDoc.TextCurrentWord;
    fSymbols[CL] := fDoc.lineTextAtCarret();
    fSymbols[CS] := fDoc.selTextUTF8;
  end;
  // project interface
  if hasProjItf then
  begin
    fname := fProjInterface.filename;
    fSymbols[CPF] := fname;
    fSymbols[CPP] := fSymbols[CPF].extractFilePath;
    fSymbols[CPN] := fSymbols[CPF].extractFileName.stripFileExt;
    fSymbols[CPO] := fProjInterface.outputFilename;
    fSymbols[CPOP]:= fSymbols[CPO].extractFileDir;
    fSymbols[CPR] := fSymbols[CPP];
    if fProjInterface.sourcesCount <> 0 then
    begin
      str := TStringList.Create;
      try
        for i := 0 to fProjInterface.sourcesCount-1 do
        begin
          fname := fProjInterface.sourceAbsolute(i);
          if not isEditable(fname.extractFileExt) then
            continue;
          str.Add(fname);
        end;
        fSymbols[CPFS] := str.Text;
        if str.Count = 1 then
          fSymbols[CPCD] := str[0].extractFileDir
        else
          fSymbols[CPCD] := commonFolder(str);
      finally
        str.Free;
      end;
    end;
  end;
  if hasNativeProj then
  begin
    if fProj.fileName.fileExists then
    begin
      if fProj.version.isNotEmpty then
        fSymbols[CPV] := fProj.version;
      fSymbols[CPR] := expandFilenameEx(fProj.basePath, fProj.RootFolder);
      if fSymbols[CPR].isEmpty then
        fSymbols[CPR] := fSymbols[CPP];
    end;
  end;
  //
  for e := FirstVariableSymbol to high(TCESymbol) do
    if fSymbols[e].isEmpty then
      fSymbols[e] := na;
end;

function TCESymbolExpander.singleServiceName: string;
begin
  exit('ICESymStringExpander');
end;

function TCESymbolExpander.expand(const value: string): string;
var
  rng: TStringRange = (ptr:nil; pos:0; len: 0);
  sym: string;
begin
  Result := '';
  if value.isEmpty then
    exit;
  //
  updateSymbols;
  rng.init(value);
  while true do
  begin
    if rng.empty then
      break;
    Result += rng.takeUntil('<').yield;
    if not rng.empty and (rng.front = '<') then
    begin
      ;
      sym := rng.popFront^.takeUntil('>').yield;
      if not rng.empty and (rng.front = '>') then
      begin
        rng.popFront;
        case sym of
          'ENV_HOME': Result += fSymbols[ENV_HOME];
          'ENV_TEMP': Result += fSymbols[ENV_TEMP];
          'ENV_USER': Result += fSymbols[ENV_USER];
          //
          'CAF', 'CoeditApplicationFile': Result += fSymbols[CAF];
          'CAP', 'CoeditApplicationPath': Result += fSymbols[CAP];
          //
          'CFF', 'CurrentFileFile'      : Result += fSymbols[CFF];
          'CFR', 'CurrentFileRunnable'  : Result += fSymbols[CFR];
          'CFP', 'CurrentFilePath'      : Result += fSymbols[CFP];
          'CI',  'CurrentIdentifier'    : Result += fSymbols[CI];
          'CL',  'CurrentLine'          : Result += fSymbols[CL];
          'CS',  'CurrentSelection'     : Result += fSymbols[CS];
          //
          'CPF', 'CurrentProjectFile'   : Result += fSymbols[CPF];
          'CPFS','CurrentProjectFiles'  : Result += fSymbols[CPFS];
          'CPN', 'CurrentProjectName'   : Result += fSymbols[CPN];
          'CPO', 'CurrentProjectOutput' : Result += fSymbols[CPO];
          'CPOP','CurrentProjectOutputPath' : Result += fSymbols[CPOP];
          'CPP', 'CurrentProjectPath'   : Result += fSymbols[CPP];
          'CPR', 'CurrentProjectRoot'   : Result += fSymbols[CPR];
          'CPCD','CurrentProjectCommonDirectory': Result += fSymbols[CPCD];
          'CPV', 'CurrentProjectVersion': Result += fSymbols[CPV];
          //
          else Result += '<' + sym + '>';
        end;
      end
      else Result += '<' + sym;
    end;
  end;
end;
{$ENDREGION}

initialization
  symbolExpander := TCESymbolExpander.Create;

finalization
  symbolExpander.Free;
end.
