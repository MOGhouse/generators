<?php

/*
 * Copyright (c) 2012, Matthias Bolte (matthias@tinkerforge.com)
 *
 * Redistribution and use in source and binary forms of this file,
 * with or without modification, are permitted.
 */

namespace Tinkerforge;


class Base58
{
    private static $alphabet = '123456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';

    /**
     * Encode string from Base10 to Base58.
     *
     * \param $value Base10 encoded string
     * \returns Base58 encoded string
     */
    public static function encode($value)
    {
        $encoded = '';

        while (bccomp($value, '58') >= 0) {
            $div = bcdiv($value, '58');
            $mod = bcmod($value, '58');
            $encoded = self::$alphabet[intval($mod)] . $encoded;
            $value = $div;
        }

        return self::$alphabet[intval($value)] . $encoded;
    }

    /**
     * Decode string from Base58 to Base10.
     *
     * \param $encoded Base58 encoded string
     * \returns Base10 encoded string
     */
    public static function decode($encoded)
    {
        $length = strlen($encoded);
        $value = '0';
        $base = '1';

        for ($i = $length - 1; $i >= 0; $i--)
        {
            $index = strval(strpos(self::$alphabet, $encoded[$i]));
            $value = bcadd($value, bcmul($index, $base));
            $base = bcmul($base, '58');
        }

        return $value;
    }
}


class TimeoutException extends \Exception
{

}


class NotSupportedException extends \Exception
{

}


abstract class Device
{
    /**
     * @internal
     */
    const RESPONSE_EXPECTED_INVALID_FUNCTION_ID = 0;
    const RESPONSE_EXPECTED_ALWAYS_TRUE = 1; // getter
    const RESPONSE_EXPECTED_ALWAYS_FALSE = 2; // callback
    const RESPONSE_EXPECTED_TRUE = 3; // setter
    const RESPONSE_EXPECTED_FALSE = 4; // setter, default

    public $uid = '0'; # Base10
    public $apiVersion = array(0, 0, 0);

    public $ipcon = NULL;

    public $responseExpected = array();

    public $expectedResponseFunctionID = 0;
    public $expectedResponseSequenceNumber = 0;
    public $receivedResponse = NULL;

    public $registeredCallbacks = array();
    public $registeredCallbackUserData = array();
    public $callbackWrappers = array();
    public $pendingCallbacks = array();

    public function __construct($uid_str, $ipcon)
    {
        $this->uid = Base58::decode($uid_str);

        $this->ipcon = $ipcon;

        for ($i = 0; $i < 256; ++$i) {
            $this->responseExpected[$i] = self::RESPONSE_EXPECTED_INVALID_FUNCTION_ID;
        }

        $ipcon->devices[$this->uid] = $this;
    }

    /**
     * Returns the name (including the hardware version), the firmware version
     * and the binding version of the device. The firmware and binding versions
     * are given in arrays of size 3 with the syntax (major, minor, revision).
     *
     * The returned array contains name, firmwareVersion and bindingVersion.
     */
    public function getAPIVersion()
    {
        return $this->apiVersion;
    }

    public function getResponseExpected($functionID) {
        if ($functionID < 0 || $functionID > 255) {
            throw new \Exception('Invalid function ID');
        }

        if ($this->responseExpected[$functionID] == self::RESPONSE_EXPECTED_ALWAYS_TRUE ||
            $this->responseExpected[$functionID] == self::RESPONSE_EXPECTED_TRUE) {
            return TRUE;
        } else if ($this->responseExpected[$functionID] == self::RESPONSE_EXPECTED_ALWAYS_FALSE ||
                   $this->responseExpected[$functionID] == self::RESPONSE_EXPECTED_FALSE) {
            return FALSE;
        } else {
            throw new \Exception('Invalid function ID');
        }
    }

    public function setResponseExpected($functionID, $responseExpected) {
        if ($this->responseExpected[$functionID] != self::RESPONSE_EXPECTED_TRUE &&
            $this->responseExpected[$functionID] != self::RESPONSE_EXPECTED_FALSE) {
            return;
        }

        $this->responseExpected[$functionID] = $responseExpected ? self::RESPONSE_EXPECTED_TRUE
                                                                 : self::RESPONSE_EXPECTED_FALSE;
    }

    public function setResponseExpectedAll($responseExpected) {
        $flag = $responseExpected ? self::RESPONSE_EXPECTED_TRUE : self::RESPONSE_EXPECTED_FALSE;

        for ($i = 0; $i < 256; ++$i) {
            if ($this->responseExpected[$i] == self::RESPONSE_EXPECTED_TRUE ||
                $this->responseExpected[$i] == self::RESPONSE_EXPECTED_FALSE) {
                $this->responseExpected[$i] = $flag;
            }
        }
    }

    /**
     * @internal
     */
    public function dispatchCallbacks()
    {
        $pendingCallbacks = $this->pendingCallbacks;
        $this->pendingCallbacks = array();

        foreach ($pendingCallbacks as $pendingCallback) {
            $this->handleCallback($pendingCallback[0], $pendingCallback[1]);
        }
    }

    /**
     * @internal
     */
    protected function sendRequest($functionID, $payload)
    {
        if ($this->ipcon->socket === FALSE) {
            throw new \Exception('Not connected');
        }

        $header = $this->ipcon->createPacketHeader($this, 8 + strlen($payload), $functionID);
        $request = $header[0] . $payload;
        $sequenceNumber = $header[1];
        $responseExpected = $header[2];

        if ($responseExpected) {
            $this->expectedResponseFunctionID = $functionID;
            $this->expectedResponseSequenceNumber = $sequenceNumber;
            $this->receivedResponse = NULL;
        }

        $this->ipcon->send($request);

        if ($responseExpected) {
            $this->ipcon->receive($this->ipcon->timeout, $this, FALSE /* FIXME: this can delay callback up to the current timeout */);

            $this->expectedResponseFunctionID = 0;
            $this->expectedResponseSequenceNumber = 0;

            if ($this->receivedResponse == NULL) {
                throw new TimeoutException('Did not receive response in time');
            }

            $response = $this->receivedResponse;
            $this->receivedResponse = NULL;

            $errorCode = ($response[0]['errorCodeAndFutureUse'] >> 6) & 0x03;

            if ($errorCode == 0) {
                // no error
            } else if ($errorCode == 1) {
                throw new NotSupportedException("Got invalid parameter for function $functionID");
            } else if ($errorCode == 2) {
                throw new NotSupportedException("Function $functionID is not supported");
            } else {
                throw new NotSupportedException("Function $functionID returned an unknown error");
            }

            $payload = $response[1];
        } else {
            $payload = NULL;
        }

        return $payload;
    }
}


class IPConnection
{
    // IDs for registerCallback
    const CALLBACK_ENUMERATE = 253;
    const CALLBACK_CONNECTED = 0;
    const CALLBACK_DISCONNECTED = 1;
    const CALLBACK_AUTHENTICATION_ERROR = 2;

    // enumerationType parameter of CALLBACK_ENUMERATE
    const ENUMERATION_TYPE_AVAILABLE = 0;
    const ENUMERATION_TYPE_CONNECTED = 1;
    const ENUMERATION_TYPE_DISCONNECTED = 2;

    // connectReason parameter of CALLBACK_CONNECTED
    const CONNECT_REASON_REQUEST = 0;

    // disconnectReason parameter of CALLBACK_DISCONNECTED
    const DISCONNECT_REASON_REQUEST = 0;
    const DISCONNECT_REASON_ERROR = 1;
    const DISCONNECT_REASON_SHUTDOWN = 2;

    // returned by getConnectionState
    const CONNECTION_STATE_DISCONNECTED = 0;
    const CONNECTION_STATE_CONNECTED = 1;

    public $timeout = 2.5; // seconds

    private $nextSequenceNumber = 0;

    public $devices = array();

    private $registeredCallbacks = array();
    private $registeredCallbackUserData = array();
    private $pendingCallbacks = array();

    public $socket = FALSE;
    private $pendingData = '';

    /**
     * Creates an IP connection to the Brick Daemon with the given *$host*
     * and *$port*. With the IP connection itself it is possible to enumerate the
     * available devices. Other then that it is only used to add Bricks and
     * Bricklets to the connection.
     *
     * @param string $host
     * @param int $port
     */
    public function __construct()
    {
    }

    function __destruct()
    {
        if ($this->socket !== FALSE) {
            $this->disconnect();
        }
    }

    public function connect($host, $port)
    {
        if ($this->socket !== FALSE) {
            throw new \Exception('Already connected');
        }

        $address = '';

        if (preg_match('/^\d+\.\d+\.\d+\.\d+$/', $host) == 0) {
            $address = gethostbyname($host);

            if ($address == $host) {
                throw new \Exception('Could not resolve hostname');
            }
        } else {
            $address = $host;
        }

        $this->socket = @socket_create(AF_INET, SOCK_STREAM, SOL_TCP);

        if ($this->socket === FALSE) {
            throw new \Exception('Could not create socket: ' .
                                 socket_strerror(socket_last_error()));
        }

        if (!@socket_connect($this->socket, $address, $port)) {
            $error = socket_strerror(socket_last_error($this->socket));

            socket_close($this->socket);
            $this->socket = FALSE;

            throw new \Exception('Could not connect socket: ' . $error);
        }

        if (array_key_exists(self::CALLBACK_CONNECTED, $this->registeredCallbacks)) {
            call_user_func_array($this->registeredCallbacks[self::CALLBACK_CONNECTED],
                                 array(self::CONNECT_REASON_REQUEST,
                                       $this->registeredCallbackUserData[self::CALLBACK_CONNECTED]));
        }
    }

    public function disconnect()
    {
        if ($this->socket === FALSE) {
            throw new \Exception('Not connected');
        }

        @socket_shutdown($this->socket, 2);
        @socket_close($this->socket);
        $this->socket = FALSE;

        if (array_key_exists(self::CALLBACK_DISCONNECTED, $this->registeredCallbacks)) {
            call_user_func_array($this->registeredCallbacks[self::CALLBACK_DISCONNECTED],
                                 array(self::DISCONNECT_REASON_REQUEST,
                                       $this->registeredCallbackUserData[self::CALLBACK_DISCONNECTED]));
        }
    }

    public function getConnectionState()
    {
        if ($this->socket !== FALSE) {
            return self::CONNECTION_STATE_CONNECTED;
        } else {
            return self::CONNECTION_STATE_DISCONNECTED;
        }
    }

    public function setTimeout($seconds)
    {
        if ($timeout < 0) {
            throw new \Exception('Timeout cannot be negative');
        }

        $this->timeout = $seconds;
    }

    public function getTimeout() // in msec
    {
        return $this->timeout;
    }

    /**
     * This method registers a callback with the signature:
     *
     *  void callback(string $uid, string $name, int $stackID, bool $isNew)
     *
     * that receives four parameters:
     *
     * - *$uid* - The UID of the device.
     * - *$name* - The name of the device (includes "Brick" or "Bricklet" and a version number).
     * - *$stackID* - The stack ID of the device (you can find out the position in a stack with this).
     * - *$isNew* - True if the device is added, false if it is removed.
     *
     * There are three different possibilities for the callback to be called.
     * Firstly, the callback is called with all currently available devices in the
     * IP connection (with *$isNew* true). Secondly, the callback is called if
     * a new Brick is plugged in via USB (with *$isNew* true) and lastly it is
     * called if a Brick is unplugged (with *$isNew* false).
     *
     * It should be possible to implement "plug 'n play" functionality with this
     * (as is done in Brick Viewer).
     *
     * You need to call IPConnection::dispatchCallbacks() in order to receive
     * the callbacks. The recommended dispatch time is 2.5s.
     *
     * @return void
     */
    public function enumerate()
    {
        $result = $this->createPacketHeader(NULL, 8, self::FUNCTION_ENUMERATE);

        $request = $result[0];

        $this->send($request);
    }

    public function registerCallback($id, $callback, $userData = NULL)
    {
        if (!is_callable($callback)) {
            throw new \Exception('Callback function is not callable');
        }

        $this->registeredCallbacks[$id] = $callback;
        $this->registeredCallbackUserData[$id] = $userData;
    }

    /**
     * Dispatches incoming callbacks for the given amount of time (negative value
     * means infinity). Because PHP doesn't support threads you need to call this
     * method periodically to ensure that incoming callbacks are handled. If you
     * don't use callbacks you don't need to call this method.
     *
     * @param float $seconds
     *
     * @return void
     */
    public function dispatchCallbacks($seconds)
    {
        // Dispatch all pending callbacks
        $pendingCallbacks = $this->pendingCallbacks;
        $this->pendingCallbacks = array();

        foreach ($pendingCallbacks as $pendingCallback) {
            if ($pendingCallback[0]['functionID'] == self::CALLBACK_ENUMERATE) {
                $this->handleEnumerate($pendingCallback[0], $pendingCallback[1]);
            }
        }

        foreach ($this->devices as $device) {
            $device->dispatchCallbacks();
        }

        if ($seconds < 0) {
            while (TRUE) {
                $this->receive($this->timeout, NULL, TRUE);

                // Dispatch all pending callbacks that were received by getters in the meantime
                foreach ($this->devices as $device) {
                    $device->dispatchCallbacks();
                }
            }
        } else {
            $this->receive($seconds, NULL, TRUE);
        }
    }

    /**
     * @internal
     */
    public function createPacketHeader($device, $length, $functionID)
    {
        $uid = '0';
        $sequenceNumber = $this->nextSequenceNumber + 1;
        $this->nextSequenceNumber = ($this->nextSequenceNumber + 1) % 15;
        $responseExpected = 0;

        if ($device != NULL) {
            $uid = $device->uid;

            if ($device->getResponseExpected($functionID)) {
                $responseExpected = 1;
            }
        }

        $sequenceNumberAndOptions = ($sequenceNumber << 4) | ($responseExpected << 3);
        $header = pack('VCCCC', $uid, $length, $functionID, $sequenceNumberAndOptions, 0);

        return array($header, $sequenceNumber, $responseExpected);
    }

    /**
     * @internal
     */
    public function send($request)
    {
        if (@socket_send($this->socket, $request, strlen($request), 0) === FALSE) {
            throw new \Exception('Could not send request: ' .
                                 socket_strerror(socket_last_error($this->socket)));
        }
    }

    /**
     * @internal
     */
    public function receive($seconds, $device, $directCallbackDispatch)
    {
        if ($seconds < 0) {
            $seconds = 0;
        }

        $start = microtime(true);
        $end = $start + $seconds;

        do {
            $read = array($this->socket);
            $write = NULL;
            $except = array($this->socket);
            $timeout = $end - microtime(true);

            if ($timeout < 0) {
                $timeout = 0;
            }

            $timeout_sec = floor($timeout);
            $timeout_usec = ceil(($timeout - $timeout_sec) * 1000000);
            $changed = @socket_select($read, $write, $except, $timeout_sec, $timeout_usec);

            if ($changed === FALSE) {
                throw new \Exception('Could not receive response: ' .
                                     socket_strerror(socket_last_error($this->socket)));
            } else if ($changed > 0) {
                if (in_array($this->socket, $except)) {
                    @socket_close($this->socket);
                    $this->socket = FALSE;

                    if (array_key_exists(self::CALLBACK_DISCONNECTED, $this->registeredCallbacks)) {
                        call_user_func_array($this->registeredCallbacks[self::CALLBACK_DISCONNECTED],
                                             array(self::DISCONNECT_REASON_ERROR,
                                                   $this->registeredCallbackUserData[self::CALLBACK_DISCONNECTED]));
                    }

                    return;
                }

                $data = '';
                $length = @socket_recv($this->socket, $data, 8192, 0);

                if ($length === FALSE || $length == 0) {
                    @socket_close($this->socket);
                    $this->socket = FALSE;

                    if ($length === FALSE) {
                        $disconnectReason = self::DISCONNECT_REASON_ERROR;
                    } else {
                        $disconnectReason = self::DISCONNECT_REASON_SHUTDOWN;
                    }

                    if (array_key_exists(self::CALLBACK_DISCONNECTED, $this->registeredCallbacks)) {
                        call_user_func_array($this->registeredCallbacks[self::CALLBACK_DISCONNECTED],
                                             array($disconnectReason,
                                                   $this->registeredCallbackUserData[self::CALLBACK_DISCONNECTED]));
                    }

                    return;
                }

                $before = microtime(true);

                $this->pendingData .= $data;

                while (TRUE) {
                    if (strlen($this->pendingData) < 8) {
                        // Wait for complete header
                        break;
                    }

                    $header = unpack('Vuid/Clength', $this->pendingData);
                    $length = $header['length'];

                    if (strlen($this->pendingData) < $length) {
                        // Wait for complete packet
                        break;
                    }

                    $packet = substr($this->pendingData, 0, $length);
                    $this->pendingData = substr($this->pendingData, $length);

                    $this->handleResponse($packet, $directCallbackDispatch);
                }

                $after = microtime(true);

                if ($after > $before) {
                    $end += $after - $before;
                }

                if ($device != NULL && $device->receivedResponse != NULL) {
                    break;
                }
            }

            $now = microtime(true);
        } while ($now >= $start && $now < $end);
    }

    /**
     * @internal
     */
    private function handleResponse($packet, $directCallbackDispatch)
    {
        $header = unpack('Vuid/Clength/CfunctionID/CsequenceNumberAndOptions/CerrorCodeAndFutureUse', $packet);
        $uid = $header['uid'];
        $functionID = $header['functionID'];
        $sequenceNumber = ($header['sequenceNumberAndOptions'] >> 4) & 0x0F;
        $payload = substr($packet, 8);

        if ($sequenceNumber == 0 && $functionID == self::CALLBACK_ENUMERATE) {
            if (array_key_exists(self::CALLBACK_ENUMERATE, $this->registeredCallbacks)) {
                if ($directCallbackDispatch) {
                    $this->handleEnumerate($header, $payload);
                } else {
                    array_push($this->pendingCallbacks, array($header, $payload));
                }
            }

            return;
        }

        if (!array_key_exists($uid, $this->devices)) {
            // Response from an unknown device, ignoring it
            return;
        }

        $device = $this->devices[$uid];

        if ($sequenceNumber == 0) {
            if (array_key_exists($functionID, $device->registeredCallbacks)) {
                if ($directCallbackDispatch) {
                    $device->handleCallback($header, $payload);
                } else {
                    array_push($device->pendingCallbacks, array($header, $payload));
                }
            }

            return;
        }

        if ($device->expectedResponseFunctionID == $functionID &&
            $device->expectedResponseSequenceNumber == $sequenceNumber) {
            $device->receivedResponse = array($header, $payload);
            return;
        }

        // Response seems to be OK, but can't be handled, most likely
        // a callback without registered callback function
    }

    /**
     * @internal
     */
    private function handleEnumerate($header, $payload)
    {
        if (!array_key_exists(self::CALLBACK_ENUMERATE, $this->registeredCallbacks)) {
            return;
        }

        $payload = unpack('c8uid/c8connectedUid/cposition/C3hardwareVersion/C3firmwareVersion/vdeviceIdentifier/CenumerationType', $payload);

        $uid = self::implodeUnpackedString($payload, 'uid', 8);
        $connectedUid = self::implodeUnpackedString($payload, 'connectedUid', 8);
        $position = chr($payload['position']);
        $hardwareVersion = self::collectUnpackedArray($payload, 'hardwareVersion', 3);
        $firmwareVersion = self::collectUnpackedArray($payload, 'firmwareVersion', 3);
        $deviceIdentifier = $payload['deviceIdentifier'];
        $enumerationType = $payload['enumerationType'];

        call_user_func_array($this->registeredCallbacks[self::CALLBACK_ENUMERATE],
                             array($uid, $connectedUid, $position, $hardwareVersion,
                                   $firmwareVersion, $deviceIdentifier, $enumerationType,
                                   $this->registeredCallbackUserData[self::CALLBACK_ENUMERATE]));
    }

    /**
     * @internal
     */
    static public function fixUnpackedInt16($value)
    {
        if ($value >= 32768) {
            $value -= 65536;
        }

        return $value;
    }

    /**
     * @internal
     */
    static public function fixUnpackedInt32($value)
    {
        if (bccomp($value, '2147483648') >= 0) {
            $value = bcsub($value, '4294967296');
        }

        return $value;
    }

    /**
     * @internal
     */
    static public function fixUnpackedUInt32($value)
    {
        if (bccomp($value, 0) < 0) {
            $value = bcadd($value, '4294967296');
        }

        return $value;
    }

    /**
     * @internal
     */
    static public function collectUnpackedInt16Array($payload, $field, $length)
    {
        $result = array();

        for ($i = 1; $i <= $length; $i++) {
            array_push($result, self::fixUnpackedInt16($payload[$field . $i]));
        }

        return $result;
    }

    /**
     * @internal
     */
    static public function collectUnpackedInt32Array($payload, $field, $length)
    {
        $result = array();

        for ($i = 1; $i <= $length; $i++) {
            array_push($result, self::fixUnpackedInt32($payload[$field . $i]));
        }

        return $result;
    }

    /**
     * @internal
     */
    static public function collectUnpackedUInt32Array($payload, $field, $length)
    {
        $result = array();

        for ($i = 1; $i <= $length; $i++) {
            array_push($result, self::fixUnpackedUInt32($payload[$field . $i]));
        }

        return $result;
    }

    /**
     * @internal
     */
    static public function collectUnpackedBoolArray($payload, $field, $length)
    {
        $result = array();

        for ($i = 1; $i <= $length; $i++) {
            array_push($result, (bool)$payload[$field . $i]);
        }

        return $result;
    }

    /**
     * @internal
     */
    static public function implodeUnpackedString($payload, $field, $length)
    {
        $result = array();

        for ($i = 1; $i <= $length; $i++) {
            $c = $payload[$field . $i];

            if ($c == 0) {
                break;
            }

            array_push($result, chr($c));
        }

        return implode($result);
    }

    /**
     * @internal
     */
    static public function collectUnpackedCharArray($payload, $field, $length)
    {
        $result = array();

        for ($i = 1; $i <= $length; $i++) {
            array_push($result, chr($payload[$field . $i]));
        }

        return $result;
    }

    /**
     * @internal
     */
    static public function collectUnpackedArray($payload, $field, $length)
    {
        $result = array();

        for ($i = 1; $i <= $length; $i++) {
            array_push($result, $payload[$field . $i]);
        }

        return $result;
    }
}

?>
