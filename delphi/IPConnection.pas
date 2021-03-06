unit IPConnection;

{$ifdef FPC}{$mode OBJFPC}{$H+}{$endif}

interface

uses
  {$ifdef FPC}
   {$ifdef UNIX}CThreads, Errors, NetDB, BaseUnix, {$else}WinSock,{$endif}
  {$else}
   {$ifdef MSWINDOWS}Windows,{$endif}
  {$endif}
  Classes, Sockets, SyncObjs, SysUtils, Base58, LEConverter, BlockingQueue, Device;

const
  FUNCTION_ENUMERATE = 254;

  CALLBACK_ENUMERATE = 253;
  CALLBACK_CONNECTED = 0;
  CALLBACK_DISCONNECTED = 1;
  CALLBACK_AUTHENTICATION_ERROR = 2;

  QUEUE_KIND_EXIT = 0;
  QUEUE_KIND_META = 1;
  QUEUE_KIND_PACKET = 2;

  { enumerationType parameter of the TIPConnectionNotifyEnumerate }
  ENUMERATION_TYPE_AVAILABLE = 0;
  ENUMERATION_TYPE_CONNECTED = 1;
  ENUMERATION_TYPE_DISCONNECTED = 2;

  { connectReason parameter of the TIPConnectionNotifyConnected }
  CONNECT_REASON_REQUEST = 0;
  CONNECT_REASON_AUTO_RECONNECT = 1;

  { disconnectReason parameter of the TIPConnectionNotifyDisconnected }
  DISCONNECT_REASON_REQUEST = 0;
  DISCONNECT_REASON_ERROR = 1;
  DISCONNECT_REASON_SHUTDOWN = 2;

  { returned by GetConnectionState }
  CONNECTION_STATE_DISCONNECTED = 0;
  CONNECTION_STATE_CONNECTED = 1;
  CONNECTION_STATE_PENDING = 2; { auto-reconnect in progress }

{$ifdef FPC}
 {$ifdef MSWINDOWS}
  ESysEINTR = WSAEINTR;
 {$endif}
{$else}
  ESysEINTR = 10004;
{$endif}

type
  { TWrapperThread }
  TThreadProcedure = procedure(opaque1: TObject; opaque2: TObject) of object;
  TWrapperThread = class(TThread)
  private
    proc: TThreadProcedure;
    opaque1: TObject;
    opaque2: TObject;
  public
    constructor Create(const proc_: TThreadProcedure; opaque1_: TObject; opaque2_: TObject);
    procedure Execute; override;
    function IsCurrent: boolean;
  end;

  { TIPConnection }
  TIPConnectionNotifyEnumerate = procedure(sender: TObject; const uid: string; const connectedUid: string;
                                           const position: char; const hardwareVersion: TVersionNumber;
                                           const firmwareVersion: TVersionNumber; const deviceIdentifier: word;
                                           const enumerationType: byte) of object;
  TIPConnectionNotifyConnected = procedure(sender: TObject; const connectReason: byte) of object;
  TIPConnectionNotifyDisconnected = procedure(sender: TObject; const disconnectReason: byte) of object;
  TIPConnection = class
  public
    socketMutex: TCriticalSection;
    timeout: longint;
    devices: TDeviceTable;
  private
    host: string;
    port: word;
    autoReconnect: boolean;
    autoReconnectAllowed: boolean;
    autoReconnectPending: boolean;
    receiveFlag: boolean;
    receiveThread: TWrapperThread;
    callbackQueue: TBlockingQueue;
    callbackThread: TWrapperThread;
    sequenceNumberMutex: TCriticalSection;
    nextSequenceNumber: byte;
    pendingData: TByteArray;
{$ifdef FPC}
    socket: TSocket;
{$else}
    socket: TTcpClient;
    lastSocketError: integer;
{$endif}
    enumerateCallback: TIPConnectionNotifyEnumerate;
    connectedCallback: TIPConnectionNotifyConnected;
    disconnectedCallback: TIPConnectionNotifyDisconnected;

    procedure ConnectUnlocked(const isAutoReconnect: boolean);
{$ifndef FPC}
    procedure SocketErrorOccurred(sender: TObject; socketError: integer);
{$endif}
    procedure ReceiveLoop(opaque1: TObject; opaque2: TObject);
    procedure CallbackLoop(opaque1: TObject; opaque2: TObject);
    procedure HandleResponse(const packet: TByteArray);
    procedure DispatchMeta(const meta: TByteArray);
    procedure DispatchPacket(const packet: TByteArray);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const host_: string; const port_: word);
    procedure Disconnect;
    function GetConnectionState: byte;
    procedure SetAutoReconnect(const autoReconnect_: boolean);
    function GetAutoReconnect: boolean;
    procedure SetTimeout(const timeout_: longword);
    function GetTimeout: longword;
    procedure Enumerate;

    property OnEnumerate: TIPConnectionNotifyEnumerate read enumerateCallback write enumerateCallback;
    property OnConnected: TIPConnectionNotifyConnected read connectedCallback write connectedCallback;
    property OnDisconnected: TIPConnectionNotifyDisconnected read disconnectedCallback write disconnectedCallback;

    { Internal }
    function IsConnected: boolean;
    function CreatePacket(const device: TDevice; const functionID: byte; const len: byte): TByteArray;
    procedure Send(const data: TByteArray);
  end;

  function GetUIDFromData(const data: TByteArray): longword;
  function GetLengthFromData(const data: TByteArray): byte;
  function GetFunctionIDFromData(const data: TByteArray): byte;
  function GetSequenceNumberFromData(const data: TByteArray): byte;
  function GetResponseExpectedFromData(const data: TByteArray): boolean;
  function GetErrorCodeFromData(const data: TByteArray): byte;

implementation

{ TWrapperThread }
constructor TWrapperThread.Create(const proc_: TThreadProcedure; opaque1_: TObject; opaque2_: TObject);
begin
  proc := proc_;
  opaque1 := opaque1_;
  opaque2 := opaque2_;
  inherited Create(false);
end;

procedure TWrapperThread.Execute;
begin
  proc(opaque1, opaque2);
end;

function TWrapperThread.IsCurrent: boolean;
begin
{$ifdef FPC}
  result := GetCurrentThreadId = ThreadID;
{$else}
  result := Windows.GetCurrentThreadId = ThreadID;
{$endif}
end;

{ TIPConnection }
constructor TIPConnection.Create;
begin
  host := '';
  port := 0;
  timeout := 2500;
  autoReconnect := true;
  autoReconnectAllowed := false;
  autoReconnectPending := false;
  receiveFlag := false;
  receiveThread := nil;
  callbackQueue := nil;
  callbackThread := nil;
  sequenceNumberMutex := TCriticalSection.Create;
  nextSequenceNumber := 0;
  SetLength(pendingData, 0);
  devices := TDeviceTable.Create;
  socketMutex := TCriticalSection.Create;
{$ifdef FPC}
  socket := -1;
{$else}
  socket := nil;
{$endif}
end;

destructor TIPConnection.Destroy;
begin
  if (IsConnected) then begin
    Disconnect;
  end;
  sequenceNumberMutex.Destroy;
  devices.Destroy;
  socketMutex.Destroy;
  inherited Destroy;
end;

procedure TIPConnection.Connect(const host_: string; const port_: word);
begin
  socketMutex.Acquire;
  try
    if (IsConnected) then begin
      raise Exception.Create('Already connected');
    end;
    host := host_;
    port := port_;
    ConnectUnlocked(false);
  finally
    socketMutex.Release;
  end;
end;

procedure TIPConnection.Disconnect;
var callbackQueue_: TBlockingQueue; callbackThread_: TWrapperThread; meta: TByteArray;
begin
  socketMutex.Acquire;
  try
    autoReconnectAllowed := false;
    if (autoReconnectPending) then begin
      { Abort pending auto-reconnect }
      autoReconnectPending := false;
    end
    else begin
      if (not IsConnected) then begin
        raise Exception.Create('Not connected');
      end;
      { Destroy receive thread }
      receiveFlag := false;
{$ifdef FPC}
      fpshutdown(socket, 2);
{$else}
      socket.Close;
{$endif}
      if (not receiveThread.IsCurrent) then begin
        receiveThread.WaitFor;
      end;
      receiveThread.Destroy;
      receiveThread := nil;
      { Destroy socket }
{$ifdef FPC}
      closesocket(socket);
      socket := -1;
{$else}
      socket := nil;
{$endif}
    end;
    { Destroy callback thread }
    callbackQueue_ := callbackQueue;
    callbackThread_ := callbackThread;
    callbackQueue := nil;
    callbackThread := nil;
  finally
    socketMutex.Release;
  end;
  { Do this outside of socketMutex to allow calling (dis-)connect from
    the callbacks while blocking on the WaitFor call here }
  SetLength(meta, 2);
  meta[0] := CALLBACK_DISCONNECTED;
  meta[1] := DISCONNECT_REASON_REQUEST;
  callbackQueue_.Enqueue(QUEUE_KIND_META, meta);
  callbackQueue_.Enqueue(QUEUE_KIND_EXIT, nil);
  if (not callbackThread_.IsCurrent) then begin
    callbackThread_.WaitFor;
  end;
end;

function TIPConnection.GetConnectionState: byte;
begin
  if (IsConnected) then begin
    result := CONNECTION_STATE_CONNECTED;
  end
  else if (autoReconnectPending) then begin
    result := CONNECTION_STATE_PENDING;
  end
  else begin
    result := CONNECTION_STATE_DISCONNECTED;
  end;
end;

procedure TIPConnection.SetAutoReconnect(const autoReconnect_: boolean);
begin
  autoReconnect := autoReconnect_;
  if (not autoReconnect) then begin
    { Abort potentially pending auto-reconnect }
    autoReconnectAllowed := false;
  end;
end;

function TIPConnection.GetAutoReconnect: boolean;
begin
  result := autoReconnect;
end;

procedure TIPConnection.SetTimeout(const timeout_: longword);
begin
  timeout := timeout_;
end;

function TIPConnection.GetTimeout: longword;
begin
  result := timeout;
end;

procedure TIPConnection.Enumerate;
var request: TByteArray;
begin
  socketMutex.Acquire;
  try
    request := CreatePacket(nil, FUNCTION_ENUMERATE, 8);
    Send(request);
  finally
    socketMutex.Release;
  end;
end;

{ NOTE: Assumes that socketMutex is locked }
procedure TIPConnection.ConnectUnlocked(const isAutoReconnect: boolean);
{$ifdef FPC}
var address: TInetSockAddr;
 {$ifdef MSWINDOWS}
    entry: PHostEnt;
 {$else}
    entry: THostEntry;
 {$endif}
    resolved: TInAddr;
{$endif}
    connectReason: word;
    meta: TByteArray;
begin
  { Create callback queue and thread }
  if (callbackThread = nil) then begin
    callbackQueue := TBlockingQueue.Create;
    callbackThread := TWrapperThread.Create({$ifdef FPC}@{$endif}self.CallbackLoop,
                                            callbackQueue, callbackThread);
  end;
  { Create and connect socket }
{$ifdef FPC}
  socket := fpsocket(AF_INET, SOCK_STREAM, 0);
  if (socket < 0) then begin
    raise Exception.Create('Could not create socket: ' + {$ifdef UNIX}strerror(socketerror){$else}SysErrorMessage(socketerror){$endif});
  end;
  resolved := StrToHostAddr(host);
  if (HostAddrToStr(resolved) <> host) then begin
 {$ifdef MSWINDOWS}
    entry := gethostbyname(PChar(host));
    if (entry = nil) then begin
      closesocket(socket);
      socket := -1;
      raise Exception.Create('Could not resolve host: ' + host);
    end;
    resolved.s_addr := longint(pointer(entry^.h_addr_list^)^);
 {$else}
    entry.Name := '';
    if (not ResolveHostByName(host, entry)) then begin
      closesocket(socket);
      socket := -1;
      raise Exception.Create('Could not resolve host: ' + host);
    end;
    resolved := entry.Addr;
 {$endif}
  end
  else begin
    resolved := HostToNet(resolved);
  end;
  address.sin_family := AF_INET;
  address.sin_port := htons(port);
  address.sin_addr := resolved;
  if (fpconnect(socket, @address, sizeof(address)) < 0) then begin
    closesocket(socket);
    socket := -1;
    raise Exception.Create('Could not connect socket: ' + {$ifdef UNIX}strerror(socketerror){$else}SysErrorMessage(socketerror){$endif});
  end;
{$else}
  socket := TTcpClient.Create(nil);
  socket.RemoteHost := TSocketHost(host);
  socket.RemotePort := TSocketPort(IntToStr(port));
  socket.BlockMode := bmBlocking;
  socket.OnError := self.SocketErrorOccurred;
  socket.Open;
  if (not socket.Connected) then begin
    socket := nil
    raise Exception.Create('Could not connect socket');
  end;
{$endif}
  { Create receive thread }
  receiveFlag := true;
  receiveThread := TWrapperThread.Create({$ifdef FPC}@{$endif}self.ReceiveLoop, nil, nil);
  autoReconnectAllowed := false;
  autoReconnectPending := false;
  { Trigger connected callback }
  if (isAutoReconnect) then begin
    connectReason := CONNECT_REASON_AUTO_RECONNECT;
  end
  else begin
    connectReason := CONNECT_REASON_REQUEST;
  end;
  SetLength(meta, 2);
  meta[0] := CALLBACK_CONNECTED;
  meta[1] := connectReason;
  callbackQueue.Enqueue(QUEUE_KIND_META, meta);
end;

{$ifndef FPC}
procedure TIPConnection.SocketErrorOccurred(sender: TObject; socketError: integer);
begin
  lastSocketError := socketError;
end;
{$endif}

procedure TIPConnection.ReceiveLoop(opaque1: TObject; opaque2: TObject);
var data: array [0..8191] of byte; len, pendingLen: longint; packet, meta: TByteArray;
begin
  while (receiveFlag) do begin
{$ifdef FPC}
    len := fprecv(socket, @data[0], Length(data), 0);
{$else}
    lastSocketError := 0;
    len := socket.ReceiveBuf(data, Length(data));
{$endif}
    if (not receiveFlag) then begin
      exit;
    end;
    if ((len < 0) or (len = 0)) then begin
{$ifdef FPC}
      if ((len < 0) and (socketerror = ESysEINTR)) then begin
{$else}
      if ((len < 0) and (lastSocketError = ESysEINTR)) then begin
{$endif}
        continue;
      end;
      autoReconnectAllowed := true;
      receiveFlag := false;
      SetLength(meta, 2);
      meta[0] := CALLBACK_DISCONNECTED;
      if (len = 0) then begin
        meta[1] := DISCONNECT_REASON_SHUTDOWN;
      end
      else begin
        meta[1] := DISCONNECT_REASON_ERROR;
      end;
      callbackQueue.Enqueue(QUEUE_KIND_META, meta);
      exit;
    end;
    pendingLen := Length(pendingData);
    SetLength(pendingData, pendingLen + len);
    Move(data[0], pendingData[pendingLen], len);
    while (true) do begin
      if (Length(pendingData) < 8) then begin
        { Wait for complete header }
        break;
      end;
      len := GetLengthFromData(pendingData);
      if (Length(pendingData) < len) then begin
        { Wait for complete packet }
        break;
      end;
      SetLength(packet, len);
      Move(pendingData[0], packet[0], len);
      Move(pendingData[len], pendingData[0], Length(pendingData) - len);
      SetLength(pendingData, Length(pendingData) - len);
      HandleResponse(packet);
    end;
  end;
end;

procedure TIPConnection.CallbackLoop(opaque1: TObject; opaque2: TObject);
var callbackQueue_: TBlockingQueue; callbackThread_: TWrapperThread; kind: byte; data: TByteArray;
begin
  callbackQueue_ := opaque1 as TBlockingQueue;
  callbackThread_ := opaque2 as TWrapperThread;
  while (true) do begin
    SetLength(data, 0);
    if (not callbackQueue_.Dequeue(kind, data, -1)) then begin
      break;
    end;
    if (kind = QUEUE_KIND_EXIT) then begin
      break;
    end
    else if (kind = QUEUE_KIND_META) then begin
      DispatchMeta(data);
    end
    else if (kind = QUEUE_KIND_PACKET) then begin
      { Don't dispatch callbacks when the receive thread isn't running }
      if (receiveFlag) then begin
        DispatchPacket(data);
      end;
    end;
  end;
  callbackQueue_.Destroy;
  callbackThread_.Destroy;
end;

procedure TIPConnection.HandleResponse(const packet: TByteArray);
var sequenceNumber, functionID: byte; device: TDevice;
begin
  functionID := GetFunctionIDFromData(packet);
  sequenceNumber := GetSequenceNumberFromData(packet);
  if ((sequenceNumber = 0) and (functionID = CALLBACK_ENUMERATE)) then begin
    if (Assigned(enumerateCallback)) then begin
      callbackQueue.Enqueue(QUEUE_KIND_PACKET, packet);
    end;
    exit;
  end;
  device := devices.Get(GetUIDFromData(packet));
  if (device = nil) then begin
    { Response from an unknown device, ignoring it }
    exit;
  end;
  if (sequenceNumber = 0) then begin
    if (Assigned(device.callbackWrappers[functionID])) then begin
      callbackQueue.Enqueue(QUEUE_KIND_PACKET, packet);
    end;
    exit;
  end;
  if ((device.expectedResponseFunctionID = functionID) and
      (device.expectedResponseSequenceNumber = sequenceNumber)) then begin
    device.responseQueue.Enqueue(0, packet);
    exit;
  end;
end;

procedure TIPConnection.DispatchMeta(const meta: TByteArray);
var retry: boolean;
begin
  if (meta[0] = CALLBACK_CONNECTED) then begin
    if (Assigned(connectedCallback)) then begin
      connectedCallback(self, meta[1]);
    end;
  end
  else if (meta[0] = CALLBACK_DISCONNECTED) then begin
    { Need to do this here, the receive loop is not allowed to hold the socket
      mutex because this could cause a deadlock with a concurrent call to the
      (dis-)connect function }
    socketMutex.Acquire;
    try
      if (IsConnected) then begin
{$ifdef FPC}
        closesocket(socket);
        socket := -1;
{$else}
        socket.Close;
        socket := nil;
{$endif}
      end;
    finally
      socketMutex.Release;
    end;
    { FIXME: Wait a moment here, otherwise the next connect attempt will
      succeed, even if there is no open server socket. the first receive will
      then fail directly }
    Sleep(100);
    if (Assigned(disconnectedCallback)) then begin
      disconnectedCallback(self, meta[1]);
    end;
    if ((meta[1] <> DISCONNECT_REASON_REQUEST) and autoReconnect and
        autoReconnectAllowed) then begin
      autoReconnectPending := true;
      retry := true;
      { Block here until reconnect. this is okay, there is no callback to
        deliver when there is no connection }
      while (retry) do begin
        retry := false;
        socketMutex.Acquire;
        try
          if (autoReconnectAllowed and (not IsConnected)) then begin
            try
              ConnectUnlocked(true);
            except
              retry := true;
            end;
          end
          else begin
            autoReconnectPending := false;
          end;
        finally
          socketMutex.Release;
        end;
        if (retry) then begin
          { Wait a moment to give another thread a chance to interrupt the
            auto-reconnect }
          Sleep(100);
        end;
      end;
    end;
  end;
end;

procedure TIPConnection.DispatchPacket(const packet: TByteArray);
var functionID: byte; uid, connectedUid: string; position: char;
    hardwareVersion, firmwareVersion: TVersionNumber;
    deviceIdentifier: word; enumerationType: byte;
    device: TDevice; callbackWrapper: TCallbackWrapper;
begin
  functionID := GetFunctionIDFromData(packet);
  if (functionID = CALLBACK_ENUMERATE) then begin
    if (Assigned(enumerateCallback)) then begin
      uid := LEConvertStringFrom(8, 8, packet);
      connectedUid := LEConvertStringFrom(16, 8, packet);
      position := LEConvertCharFrom(24, packet);
      hardwareVersion[0] := LEConvertUInt8From(25, packet);
      hardwareVersion[1] := LEConvertUInt8From(26, packet);
      hardwareVersion[2] := LEConvertUInt8From(27, packet);
      firmwareVersion[0] := LEConvertUInt8From(28, packet);
      firmwareVersion[1] := LEConvertUInt8From(29, packet);
      firmwareVersion[2] := LEConvertUInt8From(30, packet);
      deviceIdentifier := LEConvertUInt16From(31, packet);
      enumerationType := LEConvertUInt8From(33, packet);
      enumerateCallback(self, uid, connectedUid, position,
                        hardwareVersion, firmwareVersion,
                        deviceIdentifier, enumerationType);
    end
  end
  else begin
    device := devices.Get(GetUIDFromData(packet));
    if (device = nil) then begin
      exit;
    end;
    callbackWrapper := device.callbackWrappers[functionID];
    if (Assigned(callbackWrapper)) then begin
      callbackWrapper(packet);
    end;
  end;
end;

function TIPConnection.IsConnected: boolean;
begin
{$ifdef FPC}
  result := socket >= 0;
{$else}
  result := socket <> nil;
{$endif}
end;

function TIPConnection.CreatePacket(const device: TDevice; const functionID: byte; const len: byte): TByteArray;
var sequenceNumber, responseExpected: byte;
begin
  SetLength(result, len);
  FillChar(result[0], len, 0);
  sequenceNumberMutex.Acquire;
  try
    sequenceNumber := nextSequenceNumber + 1;
    nextSequenceNumber := (nextSequenceNumber + 1) mod 15;
  finally
    sequenceNumberMutex.Release;
  end;
  responseExpected := 0;
  if (device <> nil) then begin
    LEConvertUInt32To(device.uid_, 0, result);
    if (device.GetResponseExpected(functionID)) then begin
      responseExpected := 1;
    end;
  end;
  result[4] := len;
  result[5] := functionID;
  result[6] := (sequenceNumber shl 4) or (responseExpected shl 3);
end;

{ NOTE: Assumes that socketMutex is locked }
procedure TIPConnection.Send(const data: TByteArray);
begin
{$ifdef FPC}
  fpsend(socket, @data[0], Length(data), 0);
{$else}
  socket.SendBuf(data[0], Length(data));
{$endif}
end;

function GetUIDFromData(const data: TByteArray): longword;
begin
  result := LEConvertUInt32From(0, data);
end;

function GetLengthFromData(const data: TByteArray): byte;
begin
  result := data[4];
end;

function GetFunctionIDFromData(const data: TByteArray): byte;
begin
  result := data[5];
end;

function GetSequenceNumberFromData(const data: TByteArray): byte;
begin
  result := (data[6] shr 4) and $0F;
end;

function GetResponseExpectedFromData(const data: TByteArray): boolean;
begin
  if (((data[6] shr 3) and $01) = 1) then begin
    result := true;
  end
  else begin
    result := false;
  end;
end;

function GetErrorCodeFromData(const data: TByteArray): byte;
begin
  result := (data[7] shr 6) and $03;
end;

end.
