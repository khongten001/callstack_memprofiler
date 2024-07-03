unit callstack_memprofiler;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Generics.Collections, Classes, ZStream, callstack_memprofiler_common;

procedure SaveProfileToFile(filename: string = '');
procedure ReplaceMemoryManager;
function IsMemoryManagerReplaced: Boolean;
procedure RestoreMemoryManager;
procedure ResetData;

implementation

type
  {TODO: отслеживать как-то AllocMem и GetMem отдельно}

  PCodePointer = ^TCodePointer;
  TCodePointer = record
    next: array of TCodePointer;
    data: TInfo;
  end;
  PCodePointerArray = ^TCodePointerArray;
  TCodePointerArray = array of TCodePointer;
  TStackTreeArray = array of record
    name: String;
    stack_tree: TCodePointerArray;
  end;

  TMemUsageMonitor = class(specialize TDictionary<Pointer, SizeInt>)
    function AddPtr(p:pointer; Size:SizeInt):SizeInt; inline;
    function DelPtr(p:pointer):SizeInt; inline;
    function ChgPtr(p:pointer; Size:SizeInt):SizeInt; inline;
  end;

const
  skip_memusage_frames = 3;
  skip_memusage_bottom_frames = 2;

var
  root_stack: TStackTreeArray;
  mem_monitor: TMemUsageMonitor;
  NewMM, OldMM: TMemoryManager;

procedure collect_callstack(const name: String; const args: array of const; skip_frames: integer = 2; skip_bottom_frames: integer=0);
var
  frames: array [0..255] of codepointer;
  list: PCodePointerArray;
  pcp: PCodePointer;
  root: ^TStackTreeArray;
  i, i2, count: longint;
  found: boolean;
begin
  count:=CaptureBacktrace(skip_frames,255,@frames[0]);

  found:=false;
  root := @root_stack;
  for i:=high(root^) downto low(root^) do
  begin
    found := root^[i].name = name;
    if found then
    begin
      list:=@root^[i].stack_tree;
      Break;
    end;
  end;
  if not found then
  begin
    SetLength(root^, Length(root^)+1);
    root^[high(root^)].name:=name;
    list:=@root^[high(root^)].stack_tree;
  end;

  for i:=count-1-skip_bottom_frames downto 0 do
  begin
    found:=false;
    for i2:=low(list^) to high(list^) do
    begin
      pcp:=@list^[i2];
      found := pcp^.data.code_addr=frames[i];
      if found then Break;
    end;
    if not found then
    begin
      SetLength(list^, length(list^)+1);
      pcp:=@list^[high(list^)];
      pcp^.data.code_addr:=frames[i];
      pcp^.data.min_block_alloc:=High(pcp^.data.min_block_alloc);
      pcp^.data.min_block_free:=High(pcp^.data.min_block_free);
    end;
    pcp^.data.update(args);
    list:=@pcp^.next;
  end;
end;

procedure collect_memusage(mem_size:SizeInt); inline;
begin
  collect_callstack('MemUsage', [mem_size], skip_memusage_frames, skip_memusage_bottom_frames);
end;

function NewGetMem(Size:ptruint):Pointer;
begin
  Result := OldMM.GetMem(Size);

  SetMemoryManager(OldMM);
  collect_memusage(mem_monitor.AddPtr(Result, Size));
  //collect_callstack('NewGetMem',[]);
  SetMemoryManager(NewMM);
end;
function NewFreeMem(p:pointer):ptruint;
begin
  Result := OldMM.FreeMem(p);

  SetMemoryManager(OldMM);
  collect_memusage(mem_monitor.DelPtr(p));
  //collect_callstack('NewFreeMem',[]);
  SetMemoryManager(NewMM);
end;
function NewFreeMemSize(p:pointer;Size:ptruint):ptruint;
begin
  Result := OldMM.FreeMemSize(p,Size);

  SetMemoryManager(OldMM);
  collect_memusage(mem_monitor.DelPtr(p));
  //collect_callstack('NewFreeMemSize',[]);
  SetMemoryManager(NewMM);
end;
function NewAllocMem(Size:ptruint):pointer;
begin
  Result := OldMM.AllocMem(size);

  SetMemoryManager(OldMM);
  collect_memusage(mem_monitor.AddPtr(Result, Size));
  //collect_callstack('NewAllocMem',[]);
  SetMemoryManager(NewMM);
end;
function NewReAllocMem(var p:pointer;Size:ptruint):pointer;
var
  old_p:pointer;
begin
  old_p:=p;
  Result := OldMM.ReAllocMem(p,Size);

  SetMemoryManager(OldMM);
  if old_p<>p then
  begin
    collect_memusage(mem_monitor.DelPtr(old_p));
    collect_memusage(mem_monitor.AddPtr(Result, Size));
  end
  else begin
    collect_memusage(mem_monitor.ChgPtr(old_p, Size));
  end;

  //collect_callstack('NewReallocMem',[]);
  SetMemoryManager(NewMM);
end;

procedure ReplaceMemoryManager;
var
  MM: TMemoryManager;
begin
  GetMemoryManager(MM);
  if MM.AllocMem<>@NewAllocMem then
  begin
    mem_monitor:=TMemUsageMonitor.Create;

    OldMM:=MM;
    NewMM:=MM;

    NewMM.Getmem:=@NewGetMem;
    NewMM.Freemem:=@NewFreeMem;
    NewMM.FreememSize:=@NewFreeMemSize;
    NewMM.AllocMem:=@NewAllocMem;
    NewMM.ReAllocMem:=@NewReAllocMem;

    SetMemoryManager(NewMM);
  end;
end;

function IsMemoryManagerReplaced: Boolean;
var
  MM: TMemoryManager;
begin
  GetMemoryManager(MM);
  Result:=MM.AllocMem=@NewAllocMem;
end;

procedure RestoreMemoryManager;
var
  MM: TMemoryManager;
begin
  GetMemoryManager(MM);
  if MM.AllocMem=@NewAllocMem then
  begin
    SetMemoryManager(OldMM);
    mem_monitor.Free;
  end;
end;

procedure ResetData;
begin
  SetMemoryManager(OldMM);
  mem_monitor.Clear;
  SetLength(root_stack, 0);
  SetMemoryManager(NewMM);
end;

var
  bad_add_ptr_cnt:integer=0;
  bad_del_ptr_cnt:integer=0;
  bad_cng_ptr_cnt:integer=0;

function TMemUsageMonitor.AddPtr(p: pointer; Size: SizeInt): SizeInt;
begin
  if ContainsKey(p) then
  begin
    inc(bad_add_ptr_cnt);
    Exit(0);
  end;
  Result:=Size;
  Add(p, Size);
end;

function TMemUsageMonitor.DelPtr(p: pointer): SizeInt;
begin
  if not ContainsKey(p) then
  begin
    inc(bad_del_ptr_cnt);
    Exit(0);
  end;
  Result:=-Items[p];
  Remove(p);
end;

function TMemUsageMonitor.ChgPtr(p: pointer; Size: SizeInt): SizeInt;
begin
  if not ContainsKey(p) then
  begin
    inc(bad_cng_ptr_cnt);
    Exit(0);
  end;
  Result:=Size-Items[p];
  AddOrSetValue(p, Size);
end;


procedure SaveProfileToFile(filename: string = '');
var
  i,ii: Integer;
  stack_index: integer = -1;
  stack: array of PCodePointerArray;
  pstack_arr: PCodePointerArray;
  MemoryManagerWasReplaced: Boolean;
  data_size: LongInt = 0;
  ms,cs: TStream;

  procedure push(const val: PCodePointerArray); inline;
  begin
    if stack_index<Length(stack) then SetLength(stack, Length(stack)+10);
    inc(stack_index);
    stack[stack_index]:=val;
  end;
  function pop: PCodePointerArray; inline;
  begin
    Result:=stack[stack_index];
    dec(stack_index);
  end;

  procedure write_header; inline;
  begin
    ms.Seek(0, soBeginning);
    ms.WriteData(data_size);
    ms.Seek(0, soEnd);
  end;
  procedure write_node_count(const count: integer); inline;
  begin
    cs.WriteData(count);
    inc(data_size, SizeOf(count));
  end;
  procedure write_node(const data: TInfo); inline;
  begin
    cs.Write(data, SizeOf(TInfo));
    inc(data_size, SizeOf(TInfo));
  end;

begin
  i:=sizeof(TInfo);

  MemoryManagerWasReplaced:=IsMemoryManagerReplaced;

  if MemoryManagerWasReplaced then SetMemoryManager(OldMM);

  if filename='' then filename:=FormatDateTime('yyyymmddHHMMSS', Now)+'.memprof';
  ms := TMemoryStream.Create;
  cs := TCompressionStream.Create(clfastest, ms);

  write_header;
  for i:=Low(root_stack) to High(root_stack) do
  begin
    push(@root_stack[i].stack_tree);

    while stack_index>=0 do
    begin
      pstack_arr:=pop;

      write_node_count(Length(pstack_arr^));
      for ii:=Low(pstack_arr^) to High(pstack_arr^) do
      begin
        write_node(pstack_arr^[ii].data);
        push(@pstack_arr^[ii].next);
      end;
    end;
  end;
  write_header;

  cs.Free;
  TMemoryStream(ms).SaveToFile(filename);
  ms.Free;

  if MemoryManagerWasReplaced then SetMemoryManager(NewMM);
end;

procedure ExitProc;
begin
  RestoreMemoryManager;
end;

initialization
  AddExitProc(@ExitProc);

end.

