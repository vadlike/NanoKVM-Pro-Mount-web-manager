#!/usr/bin/env bash
set -euo pipefail

USERNAME="${1:-admin}"
PASSWORD="${2:-admin}"
PORT="${3:-8081}"

INSTALL_DIR="/opt/tinyfilemanager"
ROOT_DIR="${INSTALL_DIR}/root"
SERVICE_NAME="tinyfilemanager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ARIA2_SERVICE_NAME="tinyfilemanager-aria2"
ARIA2_SERVICE_FILE="/etc/systemd/system/${ARIA2_SERVICE_NAME}.service"
ARIA2_CONFIG_FILE="${INSTALL_DIR}/aria2.conf"
ARIA2_SESSION_FILE="${INSTALL_DIR}/aria2.session"
APP_FILE="${INSTALL_DIR}/tinyfilemanager.php"
INDEX_FILE="${INSTALL_DIR}/index.php"
CONFIG_FILE="${INSTALL_DIR}/config.php"
MOUNT_FILE="${INSTALL_DIR}/mount-image.php"
TORRENT_PREVIEW_DIR="${INSTALL_DIR}/torrent-previews"
TORRENT_PREVIEW_SCRIPT="${INSTALL_DIR}/torrent-preview.py"
RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0 [username] [password] [port]" >&2
  exit 1
fi

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Invalid port: ${PORT}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends aria2 ca-certificates curl php-cli php-curl php-mbstring php-zip

mkdir -p "${INSTALL_DIR}" "${ROOT_DIR}" "${TORRENT_PREVIEW_DIR}"
rm -f "${ROOT_DIR}/data" "${ROOT_DIR}/sdcard"
ln -s /data "${ROOT_DIR}/data"
ln -s /sdcard "${ROOT_DIR}/sdcard"

cat > "${TORRENT_PREVIEW_SCRIPT}" <<'PYEOF'
#!/usr/bin/env python3
import json
import sys
from pathlib import PurePosixPath


def parse_value(data, index):
    token = data[index:index + 1]
    if token == b'i':
        end = data.index(b'e', index)
        return int(data[index + 1:end]), end + 1
    if token == b'l':
        items = []
        index += 1
        while data[index:index + 1] != b'e':
            item, index = parse_value(data, index)
            items.append(item)
        return items, index + 1
    if token == b'd':
        mapping = {}
        index += 1
        while data[index:index + 1] != b'e':
            key, index = parse_value(data, index)
            value, index = parse_value(data, index)
            mapping[key] = value
        return mapping, index + 1
    if token.isdigit():
        colon = data.index(b':', index)
        size = int(data[index:colon])
        start = colon + 1
        end = start + size
        return data[start:end], end
    raise ValueError(f"Unsupported bencode token at offset {index}")


def decode_text(value):
    if isinstance(value, bytes):
        for encoding in ("utf-8", "utf-8-sig", "cp1251", "latin-1"):
            try:
                return value.decode(encoding)
            except UnicodeDecodeError:
                continue
        return value.decode("utf-8", errors="replace")
    return str(value)


def info_value(mapping, key):
    if isinstance(mapping, dict):
        utf8_key = f"{key}.utf-8".encode()
        plain_key = key.encode()
        if utf8_key in mapping:
            return mapping[utf8_key]
        return mapping.get(plain_key)
    return None


def build_preview(info):
    torrent_name = decode_text(info_value(info, "name") or b"torrent")
    files = []
    multi_files = info.get(b'files')
    if isinstance(multi_files, list):
        for position, item in enumerate(multi_files, start=1):
            length = int(item.get(b'length', 0))
            path_parts = info_value(item, "path") or []
            clean_parts = [decode_text(part).strip() for part in path_parts if decode_text(part).strip()]
            relative = str(PurePosixPath(*clean_parts)) if clean_parts else f"file-{position}"
            files.append({
                "index": position,
                "path": relative,
                "length": length,
            })
    else:
        files.append({
            "index": 1,
            "path": torrent_name,
            "length": int(info.get(b'length', 0)),
        })
    return {
        "name": torrent_name,
        "files": files,
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: torrent-preview.py <file.torrent>")
    raw = open(sys.argv[1], "rb").read()
    decoded, offset = parse_value(raw, 0)
    if offset != len(raw):
        raise ValueError("Unexpected trailing data in torrent")
    if not isinstance(decoded, dict) or b'info' not in decoded:
        raise ValueError("Invalid torrent metadata")
    preview = build_preview(decoded[b'info'])
    print(json.dumps(preview, ensure_ascii=False))


if __name__ == "__main__":
    main()
PYEOF
chmod 755 "${TORRENT_PREVIEW_SCRIPT}"

curl -fsSL "${RAW_URL}" -o "${APP_FILE}"
sed -i "s/define('APP_TITLE', 'Tiny File Manager');/define('APP_TITLE', 'NanoKVM Pro');/" "${APP_FILE}"
sed -i "s/\\\$tr\\['en'\\]\\['AppName'\\][[:space:]]*= 'Tiny File Manager';/\\\$tr['en']['AppName']        = 'NanoKVM Pro';/" "${APP_FILE}"
sed -i "s/\\\$tr\\['en'\\]\\['AppTitle'\\][[:space:]]*= 'File Manager';/\\\$tr['en']['AppTitle']       = 'NanoKVM Pro';/" "${APP_FILE}"
python3 - <<'PY'
from pathlib import Path
import re
p = Path("/opt/tinyfilemanager/tinyfilemanager.php")
s = p.read_text(encoding="utf-8")
helper_anchor = "define('APP_TITLE', 'NanoKVM Pro');\n"
favicon_tag = "<link rel=\"icon\" type=\"image/svg+xml\" href=\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%23070707'/%3E%3Crect x='4' y='4' width='56' height='56' rx='12' fill='none' stroke='%23c51616' stroke-width='4'/%3E%3Cpath d='M18 18h8v10h12V18h8v28h-8V36H26v10h-8z' fill='%23ffffff'/%3E%3C/svg%3E\">"
helper_code = """define('APP_TITLE', 'NanoKVM Pro');\n\nfunction fm_nanokvm_api($method, $path, $payload = null)\n{\n    $command = '/usr/bin/curl -sk --connect-timeout 5 --max-time 15 ';\n    if ($method === 'POST') {\n        $json = json_encode($payload ? $payload : array(), JSON_UNESCAPED_SLASHES);\n        $command .= '-X POST -H ' . escapeshellarg('Content-Type: application/json') . ' ';\n        $command .= '--data-binary ' . escapeshellarg($json) . ' ';\n    }\n    $command .= escapeshellarg('https://127.0.0.1' . $path);\n    $response = @shell_exec($command);\n    if (!is_string($response) || $response === '') {\n        return array();\n    }\n    $decoded = json_decode($response, true);\n    return is_array($decoded) ? $decoded : array();\n}\n\nfunction fm_nanokvm_mounted_image()\n{\n    static $cache = null;\n    if ($cache !== null) {\n        return $cache;\n    }\n    $cache = array('file' => '', 'cdrom' => false, 'readOnly' => false);\n    $response = fm_nanokvm_api('GET', '/api/storage/image/mounted');\n    if (isset($response['data']) && is_array($response['data'])) {\n        $cache = array_merge($cache, $response['data']);\n    }\n    return $cache;\n}\n\nfunction fm_nanokvm_aria2_restart()\n{\n    @shell_exec('systemctl restart tinyfilemanager-aria2.service >/dev/null 2>&1');\n    $probePayload = json_encode(array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk-probe',\n        'method' => 'aria2.getVersion',\n        'params' => array(),\n    ), JSON_UNESCAPED_SLASHES);\n    for ($i = 0; $i < 12; $i++) {\n        usleep(500000);\n        $command = '/usr/bin/curl -sS --connect-timeout 2 --max-time 4 ';\n        $command .= '-H ' . escapeshellarg('Content-Type: application/json') . ' ';\n        $command .= '--data-binary ' . escapeshellarg($probePayload) . ' ';\n        $command .= escapeshellarg('http://127.0.0.1:6800/jsonrpc');\n        $response = @shell_exec($command);\n        if (is_string($response) && strpos($response, '\"result\"') !== false) {\n            return true;\n        }\n    }\n    return false;\n}\n\nfunction fm_nanokvm_aria2_rpc_raw($payload, $timeout = 20)\n{\n    $command = '/usr/bin/curl -sS --connect-timeout 5 --max-time ' . (int)$timeout . ' ';\n    $command .= '-H ' . escapeshellarg('Content-Type: application/json') . ' ';\n    $command .= '--data-binary ' . escapeshellarg(json_encode($payload, JSON_UNESCAPED_SLASHES)) . ' ';\n    $command .= escapeshellarg('http://127.0.0.1:6800/jsonrpc');\n    $response = @shell_exec($command);\n    return is_string($response) ? $response : '';\n}\n\nfunction fm_nanokvm_aria2_rpc($method, $params = array())\n{\n    $payload = array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk',\n        'method' => 'aria2.' . $method,\n        'params' => $params,\n    );\n\n    $response = fm_nanokvm_aria2_rpc_raw($payload, 20);\n    if ($response === '') {\n        fm_nanokvm_aria2_restart();\n        $response = fm_nanokvm_aria2_rpc_raw($payload, 30);\n    }\n    if (!is_string($response) || $response === '') {\n        return array('ok' => false, 'message' => 'aria2 RPC unavailable');\n    }\n    $decoded = json_decode($response, true);\n    if (!is_array($decoded)) {\n        return array('ok' => false, 'message' => 'Invalid aria2 RPC response');\n    }\n    if (isset($decoded['error'])) {\n        $message = is_array($decoded['error']) ? ($decoded['error']['message'] ?? 'aria2 RPC error') : 'aria2 RPC error';\n        return array('ok' => false, 'message' => $message);\n    }\n    return array('ok' => true, 'result' => $decoded['result'] ?? null);\n}\n\nfunction fm_nanokvm_aria2_name($task)\n{\n    if (!empty($task['bittorrent']['info']['name'])) {\n        return (string)$task['bittorrent']['info']['name'];\n    }\n    if (!empty($task['files'][0]['path'])) {\n        return basename((string)$task['files'][0]['path']);\n    }\n    if (!empty($task['files'][0]['uris'][0]['uri'])) {\n        return basename(parse_url((string)$task['files'][0]['uris'][0]['uri'], PHP_URL_PATH) ?: (string)$task['files'][0]['uris'][0]['uri']);\n    }\n    return (string)($task['gid'] ?? 'task');\n}\n\nfunction fm_nanokvm_aria2_progress($task)\n{\n    $total = (float)($task['totalLength'] ?? 0);\n    $done = (float)($task['completedLength'] ?? 0);\n    if ($total <= 0) {\n        return 0;\n    }\n    return (int)round(($done / $total) * 100);\n}\n\nfunction fm_nanokvm_bytes_human($value)\n{\n    $bytes = (float)$value;\n    if ($bytes <= 0) {\n        return '0 B';\n    }\n    $units = array('B', 'KB', 'MB', 'GB', 'TB');\n    $unit = 0;\n    while ($bytes >= 1024 && $unit < count($units) - 1) {\n        $bytes /= 1024;\n        $unit++;\n    }\n    $precision = $bytes >= 100 || $unit === 0 ? 0 : 1;\n    return number_format($bytes, $precision, '.', '') . ' ' . $units[$unit];\n}\n\nfunction fm_nanokvm_aria2_tasks($limit = 12)\n{\n    $tasks = array();\n    foreach (array(\n        array('tellActive', array()),\n        array('tellWaiting', array(0, $limit)),\n        array('tellStopped', array(0, $limit)),\n    ) as $call) {\n        $resp = fm_nanokvm_aria2_rpc($call[0], $call[1]);\n        if ($resp['ok'] && is_array($resp['result'])) {\n            foreach ($resp['result'] as $task) {\n                if (is_array($task)) {\n                    $tasks[] = $task;\n                }\n            }\n        }\n    }\n    return $tasks;\n}\n\nfunction fm_nanokvm_stream_inline($fileLocation, $fileName)\n{\n    if (!is_file($fileLocation) || !is_readable($fileLocation)) {\n        return false;\n    }\n\n    $extension = pathinfo($fileName, PATHINFO_EXTENSION);\n    $contentType = fm_get_file_mimes($extension);\n    if (is_array($contentType)) {\n        $contentType = implode(' ', $contentType);\n    }\n    if (!is_string($contentType) || $contentType === '') {\n        $contentType = 'application/octet-stream';\n    }\n\n    $size = filesize($fileLocation);\n    if ($size === false || $size <= 0) {\n        return false;\n    }\n\n    if (session_status() === PHP_SESSION_ACTIVE) {\n        session_write_close();\n    }\n\n    header('Content-Description: File Transfer');\n    header('Expires: 0');\n    header('Cache-Control: private, max-age=0, must-revalidate');\n    header('Pragma: public');\n    header('Content-Transfer-Encoding: binary');\n    header('Content-Type: ' . $contentType);\n    header('Content-Disposition: inline; filename=\"' . str_replace('\"', '', $fileName) . '\"');\n    header('Accept-Ranges: bytes');\n    header('Content-Length: ' . $size);\n    while (ob_get_level()) {\n        ob_end_clean();\n    }\n    readfile(realpath($fileLocation));\n    return true;\n}\n"""
if helper_anchor in s and "function fm_nanokvm_api" not in s:
    s = s.replace(helper_anchor, helper_code, 1)

aria2_restart_old = """function fm_nanokvm_aria2_restart()\n{\n    @shell_exec('systemctl restart tinyfilemanager-aria2.service >/dev/null 2>&1');\n    $probePayload = json_encode(array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk-probe',\n        'method' => 'aria2.getVersion',\n        'params' => array(),\n    ), JSON_UNESCAPED_SLASHES);\n    for ($i = 0; $i < 12; $i++) {\n        usleep(500000);\n        $command = '/usr/bin/curl -sS --connect-timeout 2 --max-time 4 ';\n        $command .= '-H ' . escapeshellarg('Content-Type: application/json') . ' ';\n        $command .= '--data-binary ' . escapeshellarg($probePayload) . ' ';\n        $command .= escapeshellarg('http://127.0.0.1:6800/jsonrpc');\n        $response = @shell_exec($command);\n        if (is_string($response) && strpos($response, '\\\"result\\\"') !== false) {\n            return true;\n        }\n    }\n    return false;\n}\n\n"""
aria2_restart_new = """function fm_nanokvm_aria2_wait_ready($rounds = 12, $sleepMicros = 500000)\n{\n    $probePayload = json_encode(array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk-probe',\n        'method' => 'aria2.getVersion',\n        'params' => array(),\n    ), JSON_UNESCAPED_SLASHES);\n    for ($i = 0; $i < (int)$rounds; $i++) {\n        usleep((int)$sleepMicros);\n        $command = '/usr/bin/curl -sS --connect-timeout 2 --max-time 4 ';\n        $command .= '-H ' . escapeshellarg('Content-Type: application/json') . ' ';\n        $command .= '--data-binary ' . escapeshellarg($probePayload) . ' ';\n        $command .= escapeshellarg('http://127.0.0.1:6800/jsonrpc');\n        $response = @shell_exec($command);\n        if (is_string($response) && strpos($response, '\\\"result\\\"') !== false) {\n            return true;\n        }\n    }\n    return false;\n}\n\nfunction fm_nanokvm_aria2_restart()\n{\n    @shell_exec('systemctl restart tinyfilemanager-aria2.service >/dev/null 2>&1');\n    if (fm_nanokvm_aria2_wait_ready()) {\n        return true;\n    }\n    @shell_exec('pkill -9 -x aria2c >/dev/null 2>&1 || true');\n    @shell_exec('systemctl restart tinyfilemanager-aria2.service >/dev/null 2>&1');\n    return fm_nanokvm_aria2_wait_ready(16, 500000);\n}\n\n"""
if aria2_restart_old in s:
    s = s.replace(aria2_restart_old, aria2_restart_new, 1)

aria2_rpc_old = """function fm_nanokvm_aria2_rpc($method, $params = array())\n{\n    $payload = array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk',\n        'method' => 'aria2.' . $method,\n        'params' => $params,\n    );\n\n    $response = fm_nanokvm_aria2_rpc_raw($payload, 20);\n    if ($response === '') {\n        fm_nanokvm_aria2_restart();\n        $response = fm_nanokvm_aria2_rpc_raw($payload, 30);\n    }\n    if (!is_string($response) || $response === '') {\n        return array('ok' => false, 'message' => 'aria2 RPC unavailable');\n    }\n    $decoded = json_decode($response, true);\n    if (!is_array($decoded)) {\n        return array('ok' => false, 'message' => 'Invalid aria2 RPC response');\n    }\n    if (isset($decoded['error'])) {\n        $message = is_array($decoded['error']) ? ($decoded['error']['message'] ?? 'aria2 RPC error') : 'aria2 RPC error';\n        return array('ok' => false, 'message' => $message);\n    }\n    return array('ok' => true, 'result' => $decoded['result'] ?? null);\n}\n\n"""
aria2_rpc_new = """function fm_nanokvm_aria2_rpc($method, $params = array())\n{\n    $payload = array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk',\n        'method' => 'aria2.' . $method,\n        'params' => $params,\n    );\n\n    for ($attempt = 0; $attempt < 3; $attempt++) {\n        $response = fm_nanokvm_aria2_rpc_raw($payload, $attempt === 0 ? 20 : 30);\n        if (!is_string($response) || $response === '') {\n            fm_nanokvm_aria2_restart();\n            continue;\n        }\n        $decoded = json_decode($response, true);\n        if (!is_array($decoded)) {\n            fm_nanokvm_aria2_restart();\n            continue;\n        }\n        if (isset($decoded['error'])) {\n            $message = is_array($decoded['error']) ? ($decoded['error']['message'] ?? 'aria2 RPC error') : 'aria2 RPC error';\n            return array('ok' => false, 'message' => $message);\n        }\n        return array('ok' => true, 'result' => $decoded['result'] ?? null);\n    }\n    return array('ok' => false, 'message' => 'aria2 RPC unavailable');\n}\n\n"""
if aria2_rpc_old in s:
    s = s.replace(aria2_rpc_old, aria2_rpc_new, 1)

aria2_torrent_helper_anchor = """function fm_nanokvm_aria2_name($task)\n{\n"""
aria2_torrent_helper_code = """function fm_nanokvm_aria2_add_torrent_blob($content, $options = array())\n{\n    if (!is_string($content) || $content === '') {\n        return array('ok' => false, 'message' => 'Empty torrent content');\n    }\n\n    $payload = array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk',\n        'method' => 'aria2.addTorrent',\n        'params' => array(base64_encode($content), array(), $options),\n    );\n\n    $response = function_exists('fm_nanokvm_aria2_rpc_raw') ? fm_nanokvm_aria2_rpc_raw($payload, 60) : '';\n    if ($response === '' && function_exists('fm_nanokvm_aria2_restart')) {\n        fm_nanokvm_aria2_restart();\n        $response = function_exists('fm_nanokvm_aria2_rpc_raw') ? fm_nanokvm_aria2_rpc_raw($payload, 90) : '';\n    }\n\n    if (!is_string($response) || $response === '') {\n        return array('ok' => false, 'message' => 'aria2 RPC unavailable');\n    }\n    $decoded = json_decode($response, true);\n    if (!is_array($decoded)) {\n        return array('ok' => false, 'message' => 'Invalid aria2 RPC response');\n    }\n    if (isset($decoded['error'])) {\n        $message = is_array($decoded['error']) ? ($decoded['error']['message'] ?? 'aria2 RPC error') : 'aria2 RPC error';\n        return array('ok' => false, 'message' => $message);\n    }\n    return array('ok' => true, 'result' => $decoded['result'] ?? null);\n}\n\nfunction fm_nanokvm_aria2_name($task)\n{\n"""
if "function fm_nanokvm_aria2_add_torrent_blob" not in s and aria2_torrent_helper_anchor in s:
    s = s.replace(aria2_torrent_helper_anchor, aria2_torrent_helper_code, 1)

aria2_add_blob_old = """function fm_nanokvm_aria2_add_torrent_blob($content, $options = array())\n{\n    if (!is_string($content) || $content === '') {\n        return array('ok' => false, 'message' => 'Empty torrent content');\n    }\n\n    $payload = array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk',\n        'method' => 'aria2.addTorrent',\n        'params' => array(base64_encode($content), array(), $options),\n    );\n\n    $response = function_exists('fm_nanokvm_aria2_rpc_raw') ? fm_nanokvm_aria2_rpc_raw($payload, 60) : '';\n    if ($response === '' && function_exists('fm_nanokvm_aria2_restart')) {\n        fm_nanokvm_aria2_restart();\n        $response = function_exists('fm_nanokvm_aria2_rpc_raw') ? fm_nanokvm_aria2_rpc_raw($payload, 90) : '';\n    }\n\n    if (!is_string($response) || $response === '') {\n        return array('ok' => false, 'message' => 'aria2 RPC unavailable');\n    }\n    $decoded = json_decode($response, true);\n    if (!is_array($decoded)) {\n        return array('ok' => false, 'message' => 'Invalid aria2 RPC response');\n    }\n    if (isset($decoded['error'])) {\n        $message = is_array($decoded['error']) ? ($decoded['error']['message'] ?? 'aria2 RPC error') : 'aria2 RPC error';\n        return array('ok' => false, 'message' => $message);\n    }\n    return array('ok' => true, 'result' => $decoded['result'] ?? null);\n}\n\n"""
aria2_add_blob_new = """function fm_nanokvm_aria2_add_torrent_blob($content, $options = array())\n{\n    if (!is_string($content) || $content === '') {\n        return array('ok' => false, 'message' => 'Empty torrent content');\n    }\n\n    $payload = array(\n        'jsonrpc' => '2.0',\n        'id' => 'nk',\n        'method' => 'aria2.addTorrent',\n        'params' => array(base64_encode($content), array(), $options),\n    );\n\n    for ($attempt = 0; $attempt < 3; $attempt++) {\n        $response = function_exists('fm_nanokvm_aria2_rpc_raw') ? fm_nanokvm_aria2_rpc_raw($payload, $attempt === 0 ? 60 : 90) : '';\n        if (!is_string($response) || $response === '') {\n            if (function_exists('fm_nanokvm_aria2_restart')) {\n                fm_nanokvm_aria2_restart();\n            }\n            continue;\n        }\n        $decoded = json_decode($response, true);\n        if (!is_array($decoded)) {\n            if (function_exists('fm_nanokvm_aria2_restart')) {\n                fm_nanokvm_aria2_restart();\n            }\n            continue;\n        }\n        if (isset($decoded['error'])) {\n            $message = is_array($decoded['error']) ? ($decoded['error']['message'] ?? 'aria2 RPC error') : 'aria2 RPC error';\n            return array('ok' => false, 'message' => $message);\n        }\n        return array('ok' => true, 'result' => $decoded['result'] ?? null);\n    }\n    return array('ok' => false, 'message' => 'aria2 RPC unavailable');\n}\n\n"""
if aria2_add_blob_old in s:
    s = s.replace(aria2_add_blob_old, aria2_add_blob_new, 1)

torrent_registry_anchor = """function fm_nanokvm_aria2_name($task)\n{\n"""
torrent_registry_code = """function fm_nanokvm_torrent_registry_path()\n{\n    return __DIR__ . '/torrent-tasks.json';\n}\n\nfunction fm_nanokvm_torrent_registry_load($limit = 12)\n{\n    $file = fm_nanokvm_torrent_registry_path();\n    if (!is_file($file) || !is_readable($file)) {\n        return array();\n    }\n    $decoded = json_decode((string)@file_get_contents($file), true);\n    if (!is_array($decoded)) {\n        return array();\n    }\n    $tasks = array();\n    foreach ($decoded as $task) {\n        if (is_array($task) && !empty($task['gid'])) {\n            $tasks[] = $task;\n        }\n    }\n    if ($limit > 0 && count($tasks) > $limit) {\n        $tasks = array_slice($tasks, 0, $limit);\n    }\n    return $tasks;\n}\n\nfunction fm_nanokvm_torrent_registry_save($tasks)\n{\n    if (!is_array($tasks)) {\n        return false;\n    }\n    $file = fm_nanokvm_torrent_registry_path();\n    return @file_put_contents($file, json_encode(array_values($tasks), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)) !== false;\n}\n\nfunction fm_nanokvm_torrent_registry_upsert($task)\n{\n    if (!is_array($task) || empty($task['gid'])) {\n        return false;\n    }\n    $tasks = fm_nanokvm_torrent_registry_load(0);\n    $filtered = array();\n    foreach ($tasks as $existing) {\n        if (!is_array($existing) || ($existing['gid'] ?? '') === ($task['gid'] ?? '')) {\n            continue;\n        }\n        $filtered[] = $existing;\n    }\n    array_unshift($filtered, $task);\n    return fm_nanokvm_torrent_registry_save($filtered);\n}\n\nfunction fm_nanokvm_torrent_registry_remove($gid)\n{\n    $tasks = fm_nanokvm_torrent_registry_load(0);\n    $filtered = array();\n    foreach ($tasks as $existing) {\n        if (!is_array($existing) || ($existing['gid'] ?? '') === $gid) {\n            continue;\n        }\n        $filtered[] = $existing;\n    }\n    return fm_nanokvm_torrent_registry_save($filtered);\n}\n\nfunction fm_nanokvm_aria2_name($task)\n{\n"""
torrent_registry_code = """function fm_nanokvm_torrent_registry_path()\n{\n    return __DIR__ . '/torrent-tasks.json';\n}\n\nfunction fm_nanokvm_torrent_registry_load($limit = 12)\n{\n    $file = fm_nanokvm_torrent_registry_path();\n    if (!is_file($file) || !is_readable($file)) {\n        return array();\n    }\n    $decoded = json_decode((string)@file_get_contents($file), true);\n    if (!is_array($decoded)) {\n        return array();\n    }\n    $tasks = array();\n    foreach ($decoded as $task) {\n        if (is_array($task) && !empty($task['gid'])) {\n            $tasks[] = $task;\n        }\n    }\n    if ($limit > 0 && count($tasks) > $limit) {\n        $tasks = array_slice($tasks, 0, $limit);\n    }\n    return $tasks;\n}\n\nfunction fm_nanokvm_torrent_registry_save($tasks)\n{\n    if (!is_array($tasks)) {\n        return false;\n    }\n    $file = fm_nanokvm_torrent_registry_path();\n    return @file_put_contents($file, json_encode(array_values($tasks), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)) !== false;\n}\n\nfunction fm_nanokvm_torrent_registry_upsert($task)\n{\n    if (!is_array($task) || empty($task['gid'])) {\n        return false;\n    }\n    $tasks = fm_nanokvm_torrent_registry_load(0);\n    $filtered = array();\n    foreach ($tasks as $existing) {\n        if (!is_array($existing) || ($existing['gid'] ?? '') === ($task['gid'] ?? '')) {\n            continue;\n        }\n        $filtered[] = $existing;\n    }\n    array_unshift($filtered, $task);\n    return fm_nanokvm_torrent_registry_save($filtered);\n}\n\nfunction fm_nanokvm_torrent_registry_remove($gid)\n{\n    $tasks = fm_nanokvm_torrent_registry_load(0);\n    $filtered = array();\n    foreach ($tasks as $existing) {\n        if (!is_array($existing) || ($existing['gid'] ?? '') === $gid) {\n            continue;\n        }\n        $filtered[] = $existing;\n    }\n    return fm_nanokvm_torrent_registry_save($filtered);\n}\n\nfunction fm_nanokvm_torrent_registry_file_progress($task)\n{\n    if (!is_array($task) || empty($task['files']) || !is_array($task['files'])) {\n        return null;\n    }\n\n    $completed = 0.0;\n    $total = 0.0;\n    $foundAny = false;\n    foreach ($task['files'] as $file) {\n        if (!is_array($file)) {\n            continue;\n        }\n        $path = (string)($file['path'] ?? '');\n        $length = (float)($file['length'] ?? 0);\n        if ($length > 0) {\n            $total += $length;\n        }\n        if ($path === '') {\n            continue;\n        }\n\n        $realPath = @realpath($path);\n        $candidate = (is_string($realPath) && $realPath !== '') ? $realPath : $path;\n        if (!is_file($candidate)) {\n            continue;\n        }\n\n        $size = @filesize($candidate);\n        if ($size === false) {\n            continue;\n        }\n\n        $foundAny = true;\n        $size = (float)$size;\n        $completed += $length > 0 ? min($size, $length) : $size;\n        if ($length <= 0) {\n            $total += $size;\n        }\n    }\n\n    if (!$foundAny && $total <= 0) {\n        return null;\n    }\n\n    $progress = $total > 0 ? (int)round(($completed / $total) * 100) : ($foundAny ? 100 : 0);\n    return array(\n        'completedLength' => (string)(int)round($completed),\n        'totalLength' => (string)(int)round($total > 0 ? $total : $completed),\n        'progress' => max(0, min(100, $progress)),\n        'status' => (($total > 0 && $completed >= $total) || ($total <= 0 && $foundAny)) ? 'complete' : 'active',\n    );\n}\n\nfunction fm_nanokvm_aria2_name($task)\n{\n"""
if "function fm_nanokvm_torrent_registry_path" not in s and torrent_registry_anchor in s:
    s = s.replace(torrent_registry_anchor, torrent_registry_code, 1)

torrent_enqueue_anchor = """function fm_nanokvm_aria2_name($task)\n{\n"""
torrent_enqueue_code = """function fm_nanokvm_aria2_enqueue($calls)\n{\n    if (!is_array($calls) || empty($calls)) {\n        return false;\n    }\n    $commands = array();\n    foreach ($calls as $call) {\n        if (!is_array($call) || empty($call[0])) {\n            continue;\n        }\n        $payload = json_encode(array(\n            'jsonrpc' => '2.0',\n            'id' => 'nk',\n            'method' => 'aria2.' . $call[0],\n            'params' => $call[1] ?? array(),\n        ), JSON_UNESCAPED_SLASHES);\n        if (!is_string($payload) || $payload === '') {\n            continue;\n        }\n        $commands[] = '/usr/bin/curl -s http://127.0.0.1:6800/jsonrpc -H ' . escapeshellarg('Content-Type: application/json') . ' --data-binary ' . escapeshellarg($payload) . ' >/dev/null 2>&1';\n    }\n    if (empty($commands)) {\n        return false;\n    }\n    $job = implode(' ; ', $commands);\n    @shell_exec('nohup sh -c ' . escapeshellarg($job) . ' >/dev/null 2>&1 &');\n    return true;\n}\n\nfunction fm_nanokvm_aria2_name($task)\n{\n"""
if "function fm_nanokvm_aria2_enqueue" not in s and torrent_enqueue_anchor in s:
    s = s.replace(torrent_enqueue_anchor, torrent_enqueue_code, 1)

aria2_name_old = """function fm_nanokvm_aria2_name($task)\n{\n    if (!empty($task['bittorrent']['info']['name'])) {\n        return (string)$task['bittorrent']['info']['name'];\n    }\n    if (!empty($task['files'][0]['path'])) {\n        return basename((string)$task['files'][0]['path']);\n    }\n    if (!empty($task['files'][0]['uris'][0]['uri'])) {\n        return basename(parse_url((string)$task['files'][0]['uris'][0]['uri'], PHP_URL_PATH) ?: (string)$task['files'][0]['uris'][0]['uri']);\n    }\n    return (string)($task['gid'] ?? 'task');\n}\n"""
aria2_name_new = """function fm_nanokvm_aria2_name($task)\n{\n    $existingName = trim((string)($task['name'] ?? ''));\n    $sourceTorrent = trim((string)($task['sourceTorrent'] ?? ''));\n\n    if (!empty($task['bittorrent']['info']['name'])) {\n        return (string)$task['bittorrent']['info']['name'];\n    }\n\n    if ($sourceTorrent !== '' && is_file($sourceTorrent)) {\n        $script = __DIR__ . '/torrent-preview.py';\n        if (is_file($script)) {\n            $command = 'python3 ' . escapeshellarg($script) . ' ' . escapeshellarg($sourceTorrent) . ' 2>/dev/null';\n            $output = @shell_exec($command);\n            if (is_string($output) && trim($output) !== '') {\n                $decoded = json_decode($output, true);\n                if (is_array($decoded) && !empty($decoded['name'])) {\n                    return trim((string)$decoded['name']);\n                }\n            }\n        }\n    }\n\n    if (!empty($task['files'][0]['path'])) {\n        $path = str_replace('\\\\', '/', (string)$task['files'][0]['path']);\n        if (!empty($task['bittorrent']['mode']) && (string)$task['bittorrent']['mode'] === 'multi') {\n            $parent = basename(dirname($path));\n            if ($parent !== '' && $parent !== '.' && $parent !== '/') {\n                return $parent;\n            }\n        }\n        $base = basename($path);\n        if ($base !== '') {\n            return $base;\n        }\n    }\n\n    if (!empty($task['files'][0]['uris'][0]['uri'])) {\n        $uriName = basename(parse_url((string)$task['files'][0]['uris'][0]['uri'], PHP_URL_PATH) ?: (string)$task['files'][0]['uris'][0]['uri']);\n        if ($uriName !== '') {\n            return $uriName;\n        }\n    }\n\n    if ($existingName !== '' && preg_match('/^[a-f0-9]{40}\\.torrent$/i', $existingName) !== 1) {\n        return $existingName;\n    }\n\n    if (!empty($task['dir'])) {\n        $dirName = basename((string)$task['dir']);\n        if ($dirName !== '') {\n            return $dirName;\n        }\n    }\n\n    return (string)($task['gid'] ?? 'task');\n}\n"""
if aria2_name_old in s:
    s = s.replace(aria2_name_old, aria2_name_new, 1)

aria2_tasks_old = """function fm_nanokvm_aria2_tasks($limit = 12)\n{\n    $tasks = array();\n    foreach (array(\n        array('tellActive', array()),\n        array('tellWaiting', array(0, $limit)),\n        array('tellStopped', array(0, $limit)),\n    ) as $call) {\n        $resp = fm_nanokvm_aria2_rpc($call[0], $call[1]);\n        if ($resp['ok'] && is_array($resp['result'])) {\n            foreach ($resp['result'] as $task) {\n                if (is_array($task)) {\n                    $tasks[] = $task;\n                }\n            }\n        }\n    }\n    return $tasks;\n}\n"""
aria2_tasks_new = """function fm_nanokvm_aria2_tasks($limit = 12)\n{\n    return function_exists('fm_nanokvm_torrent_registry_load')\n        ? fm_nanokvm_torrent_registry_load($limit)\n        : array();\n}\n"""
if aria2_tasks_old in s:
    s = s.replace(aria2_tasks_old, aria2_tasks_new, 1)

torrent_progress_old = """function fm_nanokvm_torrent_registry_file_progress($task)\n{\n    if (!is_array($task) || empty($task['files']) || !is_array($task['files'])) {\n        return null;\n    }\n\n    $completed = 0.0;\n    $total = 0.0;\n    $foundAny = false;\n    foreach ($task['files'] as $file) {\n        if (!is_array($file)) {\n            continue;\n        }\n        $path = (string)($file['path'] ?? '');\n        $length = (float)($file['length'] ?? 0);\n        if ($length > 0) {\n            $total += $length;\n        }\n        if ($path === '') {\n            continue;\n        }\n\n        $realPath = @realpath($path);\n        $candidate = (is_string($realPath) && $realPath !== '') ? $realPath : $path;\n        if (!is_file($candidate)) {\n            continue;\n        }\n\n        $size = @filesize($candidate);\n        if ($size === false) {\n            continue;\n        }\n\n        $foundAny = true;\n        $size = (float)$size;\n        $completed += $length > 0 ? min($size, $length) : $size;\n        if ($length <= 0) {\n            $total += $size;\n        }\n    }\n\n    if (!$foundAny && $total <= 0) {\n        return null;\n    }\n\n    $progress = $total > 0 ? (int)round(($completed / $total) * 100) : ($foundAny ? 100 : 0);\n    return array(\n        'completedLength' => (string)(int)round($completed),\n        'totalLength' => (string)(int)round($total > 0 ? $total : $completed),\n        'progress' => max(0, min(100, $progress)),\n        'status' => (($total > 0 && $completed >= $total) || ($total <= 0 && $foundAny)) ? 'complete' : 'active',\n    );\n}\n\n"""
torrent_progress_new = """function fm_nanokvm_torrent_candidate_dirs($task)\n{\n    $dirs = array();\n    $baseDir = rtrim(str_replace('\\\\', '/', (string)($task['dir'] ?? '')), '/');\n    if ($baseDir !== '') {\n        $dirs[] = $baseDir;\n    }\n\n    $nameCandidates = array();\n    $taskName = trim((string)($task['name'] ?? ''));\n    if ($taskName !== '') {\n        $taskName = preg_replace('/\\.torrent$/i', '', $taskName);\n        $nameCandidates[] = $taskName;\n        if (preg_match('/^\\[[^\\]]+\\]_(.+)$/u', $taskName, $matches) === 1 && !empty($matches[1])) {\n            $nameCandidates[] = trim((string)$matches[1]);\n        }\n    }\n\n    $sourceTorrent = (string)($task['sourceTorrent'] ?? '');\n    if ($sourceTorrent !== '' && is_file($sourceTorrent)) {\n        $script = __DIR__ . '/torrent-preview.py';\n        if (is_file($script)) {\n            $command = 'python3 ' . escapeshellarg($script) . ' ' . escapeshellarg($sourceTorrent) . ' 2>/dev/null';\n            $output = @shell_exec($command);\n            if (is_string($output) && trim($output) !== '') {\n                $decoded = json_decode($output, true);\n                if (is_array($decoded) && !empty($decoded['name'])) {\n                    $nameCandidates[] = trim((string)$decoded['name']);\n                }\n            }\n        }\n    }\n\n    $nameCandidates = array_values(array_unique(array_filter($nameCandidates, function ($value) {\n        return is_string($value) && trim($value) !== '';\n    })));\n    foreach ($nameCandidates as $nameCandidate) {\n        if ($baseDir !== '') {\n            $dirs[] = $baseDir . '/' . $nameCandidate;\n        }\n    }\n\n    return array_values(array_unique(array_filter($dirs, function ($value) {\n        return is_string($value) && trim($value) !== '';\n    })));\n}\n\nfunction fm_nanokvm_torrent_registry_file_progress($task)\n{\n    if (!is_array($task) || empty($task['files']) || !is_array($task['files'])) {\n        return null;\n    }\n\n    $completed = 0.0;\n    $total = 0.0;\n    $foundAny = false;\n    $candidateDirs = fm_nanokvm_torrent_candidate_dirs($task);\n    $baseDir = rtrim(str_replace('\\\\', '/', (string)($task['dir'] ?? '')), '/');\n\n    foreach ($task['files'] as $file) {\n        if (!is_array($file)) {\n            continue;\n        }\n        $path = (string)($file['path'] ?? '');\n        $length = (float)($file['length'] ?? 0);\n        if ($length > 0) {\n            $total += $length;\n        }\n        if ($path === '') {\n            continue;\n        }\n\n        $normalizedPath = str_replace('\\\\', '/', $path);\n        $relativePath = ltrim($normalizedPath, '/');\n        if ($baseDir !== '') {\n            $basePrefix = ltrim($baseDir, '/') . '/';\n            if (strpos($relativePath, $basePrefix) === 0) {\n                $relativePath = ltrim(substr($relativePath, strlen($basePrefix)), '/');\n            }\n        }\n\n        $candidates = array($normalizedPath);\n        foreach ($candidateDirs as $candidateDir) {\n            $candidateDir = rtrim(str_replace('\\\\', '/', $candidateDir), '/');\n            if ($relativePath !== '') {\n                $candidates[] = $candidateDir . '/' . $relativePath;\n            }\n        }\n\n        $resolvedCandidate = '';\n        foreach (array_values(array_unique($candidates)) as $candidatePath) {\n            $realPath = @realpath($candidatePath);\n            $candidate = (is_string($realPath) && $realPath !== '') ? $realPath : $candidatePath;\n            if (is_file($candidate)) {\n                $resolvedCandidate = $candidate;\n                break;\n            }\n        }\n        if ($resolvedCandidate === '') {\n            continue;\n        }\n\n        $size = @filesize($resolvedCandidate);\n        if ($size === false) {\n            continue;\n        }\n\n        $foundAny = true;\n        $size = (float)$size;\n        $completed += $length > 0 ? min($size, $length) : $size;\n        if ($length <= 0) {\n            $total += $size;\n        }\n    }\n\n    if (!$foundAny && $total <= 0) {\n        return null;\n    }\n\n    $progress = $total > 0 ? (int)round(($completed / $total) * 100) : ($foundAny ? 100 : 0);\n    return array(\n        'completedLength' => (string)(int)round($completed),\n        'totalLength' => (string)(int)round($total > 0 ? $total : $completed),\n        'progress' => max(0, min(100, $progress)),\n        'status' => (($total > 0 && $completed >= $total) || ($total <= 0 && $foundAny)) ? 'complete' : 'active',\n    );\n}\n\n"""
if torrent_progress_old in s and "function fm_nanokvm_torrent_candidate_dirs($task)" not in s:
    s = s.replace(torrent_progress_old, torrent_progress_new, 1)

if favicon_tag not in s and "</head>" in s:
    s = s.replace("</head>", f"        {favicon_tag}\n    </head>", 2)

footer_old = """        <?php if (!FM_READONLY): ?>\n            <div class=\"col-3 d-none d-sm-block\"><a href=\"https://tinyfilemanager.github.io\" target=\"_blank\" class=\"float-right text-muted\">Tiny File Manager <?php echo VERSION; ?></a></div>\n        <?php else: ?>\n            <div class=\"col-12\"><a href=\"https://tinyfilemanager.github.io\" target=\"_blank\" class=\"float-right text-muted\">Tiny File Manager <?php echo VERSION; ?></a></div>\n        <?php endif; ?>\n"""
if footer_old in s:
    s = s.replace(footer_old, "", 1)

login_footer_old = """                        <div class="footer text-center">\n                            &mdash;&mdash; &copy;\n                            <a href="https://tinyfilemanager.github.io/" target="_blank" class="text-decoration-none text-muted" data-version="<?php echo VERSION; ?>">CCP Programmers</a> &mdash;&mdash;\n                        </div>\n"""
if login_footer_old in s:
    s = s.replace(login_footer_old, "", 1)

login_brand_re = re.compile(r"""\s*<div class="brand">\s*<svg.*?</svg>\s*</div>\s*""", re.S)
s = login_brand_re.sub("\n", s, count=1)

main_footer_re = re.compile(r"""\s*<div class="col-(?:3 d-none d-sm-block|12)"><a href="https://tinyfilemanager\.github\.io" target="_blank" class="float-right text-muted">Tiny File Manager <\?php echo VERSION; \?></a></div>\s*""")
s = main_footer_re.sub("\n", s)

dark_bg_old = """            body.fm-login-page.theme-dark {\n                background-color: #2f2a2a;\n            }\n"""
dark_bg_new = """            body.fm-login-page,\n            body.fm-login-page.theme-dark {\n                background: #000000 !important;\n                background-color: #000000 !important;\n                background-image: none !important;\n            }\n\n            .fm-login-page .card.fat {\n                background: #111111 !important;\n                border: 1px solid #3a0a0a !important;\n                box-shadow: 0 20px 50px rgba(0, 0, 0, 0.55) !important;\n            }\n\n            .fm-login-page .card-body {\n                background: #111111 !important;\n                color: #f3f3f3 !important;\n            }\n\n            .fm-login-page .card-title,\n            .fm-login-page label,\n            .fm-login-page .pb-2 {\n                color: #f5f5f5 !important;\n            }\n\n            .fm-login-page hr {\n                border-color: rgba(185, 28, 28, 0.45) !important;\n            }\n\n            .fm-login-page .form-control {\n                color: #ffffff !important;\n                background: #1c1c1c !important;\n                border: 1px solid #4b1212 !important;\n                box-shadow: none !important;\n            }\n\n            .fm-login-page .form-control:focus {\n                border-color: #d11f1f !important;\n                box-shadow: 0 0 0 0.18rem rgba(209, 31, 31, 0.28) !important;\n            }\n\n            .fm-login-page .btn-success,\n            .fm-login-page .btn.btn-success {\n                background: linear-gradient(180deg, #c51616 0%, #8f0f0f 100%) !important;\n                border-color: #c51616 !important;\n                color: #ffffff !important;\n            }\n\n            .fm-login-page .btn-success:hover,\n            .fm-login-page .btn.btn-success:hover {\n                background: linear-gradient(180deg, #db2020 0%, #a61212 100%) !important;\n                border-color: #db2020 !important;\n            }\n"""
if dark_bg_old in s:
    s = s.replace(dark_bg_old, dark_bg_new, 1)

theme_dark_old = """body.theme-dark {\n                    background-image: linear-gradient(90deg, #1c2429, #263238);\n                    color: #CFD8DC;\n                }\n\n                .list-group .list-group-item {\n                    background: #343a40;\n                }\n\n                .theme-dark .navbar-nav i,\n                .navbar-nav .dropdown-toggle,\n                .break-word {\n                    color: #CFD8DC;\n                }\n\n                a,\n                a:hover,\n                a:visited,\n                a:active,\n                #main-table .filename a,\n                i.fa.fa-folder-o,\n                i.go-back {\n                    color: var(--bg-color);\n                }\n\n                ul#search-wrapper li:nth-child(odd) {\n                    background: #212a2f;\n                }\n\n                .theme-dark .btn-outline-primary {\n                    color: #b8e59c;\n                    border-color: #b8e59c;\n                }\n\n                .theme-dark .btn-outline-primary:hover,\n                .theme-dark .btn-outline-primary:active {\n                    background-color: #2d4121;\n                }\n\n                .theme-dark input.form-control {\n                    background-color: #101518;\n                    color: #CFD8DC;\n                }\n\n                .theme-dark .dropzone {\n                    background: transparent;\n                }\n\n                .theme-dark .inline-actions>a>i {\n                    background: #79755e;\n                }\n\n                .theme-dark .text-white {\n                    color: #CFD8DC !important;\n                }\n\n                .theme-dark .table-bordered td,\n                .table-bordered th {\n                    border-color: #343434;\n                }\n\n                .theme-dark .table-bordered td .custom-control-input,\n                .theme-dark .table-bordered th .custom-control-input {\n                    opacity: 0.678;\n                }\n\n                .message {\n                    background-color: #212529;\n                }\n\n                form.dropzone {\n                    border-color: #79755e;\n                }\n"""
theme_dark_new = """body.theme-dark {\n                    --bg-color: #ffffff;\n                    background: #050505 !important;\n                    background-image: none !important;\n                    color: #f5f5f5 !important;\n                }\n\n                .theme-dark .list-group .list-group-item,\n                .theme-dark .card,\n                .theme-dark .modal-content,\n                .theme-dark .modal-header,\n                .theme-dark .modal-body,\n                .theme-dark .modal-footer,\n                .theme-dark .dropdown-menu,\n                .theme-dark .table-responsive,\n                .theme-dark .input-group-text,\n                .theme-dark .form-control,\n                .theme-dark .form-select {\n                    background: #101010 !important;\n                    color: #f5f5f5 !important;\n                    border-color: #4a1111 !important;\n                }\n\n                .theme-dark .navbar,\n                .theme-dark .main-nav,\n                .theme-dark .bg-body-tertiary {\n                    background: #090909 !important;\n                    border-bottom: 1px solid #4a1111 !important;\n                    box-shadow: 0 10px 24px rgba(0, 0, 0, 0.45) !important;\n                }\n\n                .theme-dark .navbar-nav i,\n                .theme-dark .navbar-brand,\n                .theme-dark .navbar-nav .dropdown-toggle,\n                .theme-dark .break-word,\n                .theme-dark a,\n                .theme-dark a:hover,\n                .theme-dark a:visited,\n                .theme-dark a:active,\n                .theme-dark #main-table .filename a,\n                .theme-dark i.fa.fa-folder-o,\n                .theme-dark i.go-back,\n                .theme-dark td,\n                .theme-dark th,\n                .theme-dark label,\n                .theme-dark .text-white,\n                .theme-dark .text-muted {\n                    color: #ffffff !important;\n                }\n\n                .theme-dark ul#search-wrapper li:nth-child(odd) {\n                    background: #170b0b !important;\n                }\n\n                .theme-dark .btn,\n                .theme-dark .btn-outline-primary,\n                .theme-dark .btn-outline-success,\n                .theme-dark .btn-outline-secondary,\n                .theme-dark .btn-outline-danger,\n                .theme-dark .btn-success,\n                .theme-dark .btn-primary,\n                .theme-dark .btn-small,\n                .theme-dark .btn-2,\n                .theme-dark .btn-link {\n                    color: #ffffff !important;\n                    border-color: #8f1212 !important;\n                    background: linear-gradient(180deg, #2a0d0d 0%, #150909 100%) !important;\n                    box-shadow: none !important;\n                }\n\n                .theme-dark .btn:hover,\n                .theme-dark .btn:active,\n                .theme-dark .btn:focus,\n                .theme-dark .btn-outline-primary:hover,\n                .theme-dark .btn-outline-success:hover,\n                .theme-dark .btn-outline-secondary:hover,\n                .theme-dark .btn-outline-danger:hover,\n                .theme-dark .btn-success:hover,\n                .theme-dark .btn-primary:hover,\n                .theme-dark .btn-small:hover,\n                .theme-dark .btn-2:hover {\n                    color: #ffffff !important;\n                    border-color: #d11f1f !important;\n                    background: linear-gradient(180deg, #d11f1f 0%, #8f0f0f 100%) !important;\n                }\n\n                .theme-dark input.form-control,\n                .theme-dark textarea.form-control,\n                .theme-dark select.form-select {\n                    background-color: #0b0b0b !important;\n                    color: #ffffff !important;\n                    border-color: #5b1717 !important;\n                }\n\n                .theme-dark input.form-control:focus,\n                .theme-dark textarea.form-control:focus,\n                .theme-dark select.form-select:focus {\n                    border-color: #d11f1f !important;\n                    box-shadow: 0 0 0 0.18rem rgba(209, 31, 31, 0.25) !important;\n                }\n\n                .theme-dark .dropzone {\n                    background: #101010 !important;\n                    border-color: #8f1212 !important;\n                }\n\n                .theme-dark .inline-actions>a>i,\n                .theme-dark .fa-link,\n                .theme-dark .fa-download,\n                .theme-dark .fa-trash,\n                .theme-dark .fa-edit,\n                .theme-dark .fa-copy {\n                    background: #2a0d0d !important;\n                    color: #ffffff !important;\n                }\n\n                .theme-dark .table,\n                .theme-dark .table-bordered,\n                .theme-dark .table-bordered td,\n                .theme-dark .table-bordered th,\n                .theme-dark .table-hover tbody tr:hover > * {\n                    border-color: #341111 !important;\n                }\n\n                .theme-dark .table > :not(caption) > * > * {\n                    background: #101010 !important;\n                    color: #ffffff !important;\n                }\n\n                .theme-dark .table tbody tr:nth-child(even) > * {\n                    background: #151515 !important;\n                }\n\n                .theme-dark .table-hover tbody tr:hover > * {\n                    background: #220c0c !important;\n                }\n\n                .theme-dark .table-bordered td .custom-control-input,\n                .theme-dark .table-bordered th .custom-control-input {\n                    opacity: 0.9;\n                    accent-color: #d11f1f;\n                }\n\n                .theme-dark .message,\n                .theme-dark .alert,\n                .theme-dark .alert-success,\n                .theme-dark .alert-danger {\n                    background: #170b0b !important;\n                    color: #ffffff !important;\n                    border: 1px solid #b51616 !important;\n                }\n\n                .theme-dark .badge,\n                .theme-dark .text-bg-light,\n                .theme-dark .border-radius-0 {\n                    background: #2a0d0d !important;\n                    color: #ffffff !important;\n                    border: 1px solid #8f1212 !important;\n                }\n\n                .theme-dark .dropdown-item:hover,\n                .theme-dark .dropdown-item:focus,\n                .theme-dark .dropdown-item.active {\n                    background: #8f1212 !important;\n                    color: #ffffff !important;\n                }\n\n                .theme-dark .navbar-toggler,\n                .theme-dark .btn-close,\n                .theme-dark #search-addon {\n                    filter: invert(1) grayscale(1);\n                }\n\n                form.dropzone {\n                    border-color: #8f1212 !important;\n                }\n"""
if theme_dark_old in s:
    s = s.replace(theme_dark_old, theme_dark_new, 1)

search_css_old = """                .theme-dark .navbar-toggler,\n                .theme-dark .btn-close,\n                .theme-dark #search-addon {\n                    filter: invert(1) grayscale(1);\n                }\n"""
search_css_new = """                .theme-dark #search-addon {\n                    background: #0a0a0a !important;\n                    background-color: #0a0a0a !important;\n                    color: #ffffff !important;\n                    border-color: #8f1212 !important;\n                    filter: none !important;\n                }\n\n                .theme-dark #search-addon::placeholder {\n                    color: #e5e5e5 !important;\n                    opacity: 1 !important;\n                }\n\n                .theme-dark #search-addon2,\n                .theme-dark .input-group-append .input-group-text,\n                .theme-dark .input-group-append .dropdown-toggle {\n                    background: #111111 !important;\n                    color: #ffffff !important;\n                    border-color: #8f1212 !important;\n                    filter: none !important;\n                }\n\n                .theme-dark .navbar-toggler,\n                .theme-dark .btn-close {\n                    filter: invert(1) grayscale(1);\n                }\n"""
if search_css_old in s:
    s = s.replace(search_css_old, search_css_new, 1)

main_theme_anchor = """            .h-100vh {\n                min-height: 100vh;\n            }\n"""
main_theme_new = """            .h-100vh {\n                min-height: 100vh;\n            }\n\n            body:not(.fm-login-page) {\n                --nk-bg: #050505;\n                --nk-surface: #101010;\n                --nk-surface-2: #151515;\n                --nk-surface-3: #1c1c1c;\n                --nk-border: #3a0a0a;\n                --nk-border-strong: #7d1d1d;\n                --nk-red: #c51616;\n                --nk-red-hover: #e11d1d;\n                --nk-red-soft: #2a0d0d;\n                --nk-white: #f5f5f5;\n                --nk-muted: #d4d4d4;\n                background: var(--nk-bg) !important;\n                background-color: var(--nk-bg) !important;\n                color: var(--nk-white) !important;\n            }\n\n            body:not(.fm-login-page),\n            body:not(.fm-login-page) .container,\n            body:not(.fm-login-page) .container-fluid,\n            body:not(.fm-login-page) .table-responsive {\n                background: var(--nk-bg) !important;\n                color: var(--nk-white) !important;\n            }\n\n            body:not(.fm-login-page) .main-nav,\n            body:not(.fm-login-page) .bg-body-tertiary,\n            body:not(.fm-login-page) .navbar,\n            body:not(.fm-login-page) nav {\n                background: #090909 !important;\n                border-bottom: 1px solid var(--nk-border) !important;\n                box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45) !important;\n            }\n\n            body:not(.fm-login-page) .navbar-brand,\n            body:not(.fm-login-page) .main-nav a,\n            body:not(.fm-login-page) .breadcrumb,\n            body:not(.fm-login-page) .breadcrumb a,\n            body:not(.fm-login-page) .bread-crumb,\n            body:not(.fm-login-page) .nav-link,\n            body:not(.fm-login-page) .filename,\n            body:not(.fm-login-page) td,\n            body:not(.fm-login-page) th,\n            body:not(.fm-login-page) label,\n            body:not(.fm-login-page) .card-title,\n            body:not(.fm-login-page) .card-header,\n            body:not(.fm-login-page) .text-muted,\n            body:not(.fm-login-page) small,\n            body:not(.fm-login-page) .small {\n                color: var(--nk-white) !important;\n            }\n\n            body:not(.fm-login-page) a {\n                color: #ffffff !important;\n            }\n\n            body:not(.fm-login-page) a:hover,\n            body:not(.fm-login-page) a:focus {\n                color: #ff9b9b !important;\n            }\n\n            body:not(.fm-login-page) .table,\n            body:not(.fm-login-page) .table-bordered,\n            body:not(.fm-login-page) .table-hover,\n            body:not(.fm-login-page) .table-responsive,\n            body:not(.fm-login-page) .card,\n            body:not(.fm-login-page) .card-header,\n            body:not(.fm-login-page) .card-body,\n            body:not(.fm-login-page) .dropdown-menu,\n            body:not(.fm-login-page) .list-group-item,\n            body:not(.fm-login-page) .modal-content,\n            body:not(.fm-login-page) .modal-header,\n            body:not(.fm-login-page) .modal-body,\n            body:not(.fm-login-page) .modal-footer,\n            body:not(.fm-login-page) .input-group {\n                background: var(--nk-surface) !important;\n                background-color: var(--nk-surface) !important;\n                color: var(--nk-white) !important;\n                border-color: var(--nk-border) !important;\n            }\n\n            body:not(.fm-login-page) .table thead th,\n            body:not(.fm-login-page) .table > thead > tr > th {\n                background: #0b0b0b !important;\n                color: #ffffff !important;\n                border-color: var(--nk-border) !important;\n            }\n\n            body:not(.fm-login-page) .table > :not(caption) > * > *,\n            body:not(.fm-login-page) .table-bordered > :not(caption) > * {\n                background: var(--nk-surface) !important;\n                color: var(--nk-white) !important;\n                border-color: #2b1111 !important;\n                box-shadow: none !important;\n            }\n\n            body:not(.fm-login-page) .table tbody tr:nth-child(even) > * {\n                background: var(--nk-surface-2) !important;\n            }\n\n            body:not(.fm-login-page) .table-hover tbody tr:hover > *,\n            body:not(.fm-login-page) tr:hover > td,\n            body:not(.fm-login-page) tr:hover > th {\n                background: var(--nk-red-soft) !important;\n            }\n\n            body:not(.fm-login-page) .form-control,\n            body:not(.fm-login-page) .input-group-text,\n            body:not(.fm-login-page) .form-select,\n            body:not(.fm-login-page) input,\n            body:not(.fm-login-page) select,\n            body:not(.fm-login-page) textarea {\n                background: #0b0b0b !important;\n                color: #ffffff !important;\n                border-color: var(--nk-border) !important;\n                box-shadow: none !important;\n            }\n\n            body:not(.fm-login-page) input::placeholder,\n            body:not(.fm-login-page) textarea::placeholder {\n                color: #bdbdbd !important;\n            }\n\n            body:not(.fm-login-page) .form-control:focus,\n            body:not(.fm-login-page) .form-select:focus,\n            body:not(.fm-login-page) input:focus,\n            body:not(.fm-login-page) textarea:focus,\n            body:not(.fm-login-page) select:focus {\n                border-color: var(--nk-red) !important;\n                box-shadow: 0 0 0 0.18rem rgba(197, 22, 22, 0.25) !important;\n            }\n\n            body:not(.fm-login-page) .btn,\n            body:not(.fm-login-page) .btn-small,\n            body:not(.fm-login-page) .btn-2,\n            body:not(.fm-login-page) .btn-outline-primary,\n            body:not(.fm-login-page) .btn-outline-success,\n            body:not(.fm-login-page) .btn-outline-secondary,\n            body:not(.fm-login-page) .btn-outline-danger,\n            body:not(.fm-login-page) .btn-outline-warning,\n            body:not(.fm-login-page) .btn-primary,\n            body:not(.fm-login-page) .btn-success,\n            body:not(.fm-login-page) .btn-danger,\n            body:not(.fm-login-page) .btn-warning,\n            body:not(.fm-login-page) .btn-info,\n            body:not(.fm-login-page) .btn-secondary,\n            body:not(.fm-login-page) .btn-light,\n            body:not(.fm-login-page) .btn-dark {\n                color: #ffffff !important;\n                border-color: var(--nk-border-strong) !important;\n                background: linear-gradient(180deg, #260d0d 0%, #140909 100%) !important;\n                box-shadow: none !important;\n            }\n\n            body:not(.fm-login-page) .btn:hover,\n            body:not(.fm-login-page) .btn:focus,\n            body:not(.fm-login-page) .btn-outline-primary:hover,\n            body:not(.fm-login-page) .btn-outline-success:hover,\n            body:not(.fm-login-page) .btn-outline-secondary:hover,\n            body:not(.fm-login-page) .btn-outline-danger:hover,\n            body:not(.fm-login-page) .btn-outline-warning:hover,\n            body:not(.fm-login-page) .btn-primary:hover,\n            body:not(.fm-login-page) .btn-success:hover,\n            body:not(.fm-login-page) .btn-danger:hover,\n            body:not(.fm-login-page) .btn-warning:hover,\n            body:not(.fm-login-page) .btn-info:hover,\n            body:not(.fm-login-page) .btn-secondary:hover,\n            body:not(.fm-login-page) .btn-light:hover,\n            body:not(.fm-login-page) .btn-dark:hover {\n                color: #ffffff !important;\n                background: linear-gradient(180deg, var(--nk-red-hover) 0%, #8f0f0f 100%) !important;\n                border-color: var(--nk-red-hover) !important;\n            }\n\n            body:not(.fm-login-page) .btn-link,\n            body:not(.fm-login-page) .btn-link:hover,\n            body:not(.fm-login-page) .btn-link:focus {\n                color: #ff8a8a !important;\n                background: transparent !important;\n                border-color: transparent !important;\n            }\n\n            body:not(.fm-login-page) .message,\n            body:not(.fm-login-page) .message.ok,\n            body:not(.fm-login-page) .message.error,\n            body:not(.fm-login-page) .message.alert,\n            body:not(.fm-login-page) .alert,\n            body:not(.fm-login-page) .alert-success,\n            body:not(.fm-login-page) .alert-danger,\n            body:not(.fm-login-page) .alert-warning,\n            body:not(.fm-login-page) .alert-info {\n                background: #180909 !important;\n                color: #ffffff !important;\n                border: 1px solid var(--nk-red) !important;\n            }\n\n            body:not(.fm-login-page) .badge,\n            body:not(.fm-login-page) .bg-success,\n            body:not(.fm-login-page) .bg-primary,\n            body:not(.fm-login-page) .bg-danger,\n            body:not(.fm-login-page) .bg-warning,\n            body:not(.fm-login-page) .bg-info,\n            body:not(.fm-login-page) .text-bg-light,\n            body:not(.fm-login-page) .border-radius-0 {\n                background: #2a0d0d !important;\n                color: #ffffff !important;\n                border: 1px solid var(--nk-border-strong) !important;\n            }\n\n            body:not(.fm-login-page) .dropdown-menu,\n            body:not(.fm-login-page) .dropdown-item {\n                background: #111111 !important;\n                color: #ffffff !important;\n                border-color: var(--nk-border) !important;\n            }\n\n            body:not(.fm-login-page) .dropdown-item:hover,\n            body:not(.fm-login-page) .dropdown-item:focus,\n            body:not(.fm-login-page) .dropdown-item.active {\n                background: #8f1212 !important;\n                color: #ffffff !important;\n            }\n\n            body:not(.fm-login-page) .pagination .page-link {\n                background: #111111 !important;\n                color: #ffffff !important;\n                border-color: var(--nk-border) !important;\n            }\n\n            body:not(.fm-login-page) .pagination .page-link:hover,\n            body:not(.fm-login-page) .pagination .page-item.active .page-link {\n                background: #8f1212 !important;\n                border-color: var(--nk-red-hover) !important;\n                color: #ffffff !important;\n            }\n\n            body:not(.fm-login-page) input[type='checkbox'],\n            body:not(.fm-login-page) input[type='radio'] {\n                accent-color: var(--nk-red) !important;\n            }\n"""
if main_theme_anchor in s and "body:not(.fm-login-page)" not in s:
    s = s.replace(main_theme_anchor, main_theme_new, 1)

folder_direct_old = """                        <a title="<?php echo lng('DirectLink') ?>" href="<?php echo fm_enc(FM_ROOT_URL . (FM_PATH != '' ? '/' . FM_PATH : '') . '/' . $f . '/') ?>" target="_blank"><i class="fa fa-link" aria-hidden="true"></i></a>\n"""
folder_direct_new = """                        <a title="<?php echo lng('DirectLink') ?>" href="?p=<?php echo urlencode(trim(FM_PATH . '/' . $f, '/')) ?>" target="_blank"><i class="fa fa-link" aria-hidden="true"></i></a>\n"""
if folder_direct_old in s:
    s = s.replace(folder_direct_old, folder_direct_new, 1)

nav_with_mount = """        <a class=\"navbar-brand\"> <?php echo lng('AppTitle') ?> </a>\n        <?php $mountedInfoNav = function_exists('fm_nanokvm_mounted_image') ? fm_nanokvm_mounted_image() : array('file' => ''); ?>\n        <?php $mountedNameNav = !empty($mountedInfoNav['file']) ? basename($mountedInfoNav['file']) : ''; ?>\n        <a class=\"btn btn-sm <?php echo $mountedNameNav !== '' ? 'btn-outline-success' : 'btn-outline-primary'; ?> me-2\" href=\"mount-image.php\"><?php echo $mountedNameNav !== '' ? 'Mounted: ' . fm_enc($mountedNameNav) : 'Mount Image'; ?></a>\n"""
nav_plain = """        <a class=\"navbar-brand\"> <?php echo lng('AppTitle') ?> </a>\n"""
if nav_with_mount in s:
    s = s.replace(nav_with_mount, nav_plain, 1)

settings_link = """<a title="<?php echo lng('Settings') ?>" class="dropdown-item nav-link" href="?p=<?php echo urlencode(FM_PATH) ?>&amp;settings=1"><i class="fa fa-cog" aria-hidden="true"></i> <?php echo lng('Settings') ?></a>"""
s = s.replace(settings_link, '')
s = s.replace("if (isset($_GET['settings']) && !FM_READONLY) {", "if (false && isset($_GET['settings']) && !FM_READONLY) {", 1)

help_re = re.compile(r"if \(isset\(\$_GET\['help'\]\)\) \{.*?\n// file viewer", re.S)
help_new = """if (isset($_GET['help'])) {\n    fm_show_header(); // HEADER\n    fm_show_nav_path(FM_PATH); // current path\n?>\n\n    <div class=\"col-md-8 offset-md-2 pt-3\">\n        <div class=\"card mb-2\" data-bs-theme=\"<?php echo FM_THEME; ?>\">\n            <h6 class=\"card-header d-flex justify-content-between\">\n                <span><i class=\"fa fa-exclamation-circle\"></i> <?php echo lng('Help') ?></span>\n                <a href=\"?p=<?php echo FM_PATH ?>\" class=\"text-danger\"><i class=\"fa fa-times-circle-o\"></i> <?php echo lng('Cancel') ?></a>\n            </h6>\n            <div class=\"card-body\">\n                <?php if (!FM_READONLY): ?>\n                    <div class=\"card\">\n                        <ul class=\"list-group list-group-flush\">\n                            <li class=\"list-group-item\"><a href=\"javascript:show_new_pwd();\"><i class=\"fa fa-lock\"></i> <?php echo lng('Generate new password hash') ?></a></li>\n                            <li class=\"list-group-item\"><a href=\"javascript:show_change_pwd();\"><i class=\"fa fa-key\"></i> Change login password</a></li>\n                        </ul>\n                    </div>\n                <?php endif; ?>\n                <div class=\"row js-new-pwd hidden mt-3\">\n                    <div class=\"col-12\">\n                        <form class=\"form-inline\" onsubmit=\"return new_password_hash(this)\" method=\"POST\" action=\"\">\n                            <input type=\"hidden\" name=\"type\" value=\"pwdhash\" aria-label=\"hidden\" aria-hidden=\"true\">\n                            <div class=\"form-group mb-2\">\n                                <label for=\"staticEmail2\"><?php echo lng('Generate new password hash') ?></label>\n                            </div>\n                            <div class=\"form-group mx-sm-3 mb-2\">\n                                <label for=\"inputPassword2\" class=\"sr-only\"><?php echo lng('Password') ?></label>\n                                <input type=\"text\" class=\"form-control btn-sm\" id=\"inputPassword2\" name=\"inputPassword2\" placeholder=\"<?php echo lng('Password') ?>\" required>\n                            </div>\n                            <button type=\"submit\" class=\"btn btn-success btn-sm mb-2\"><?php echo lng('Generate') ?></button>\n                        </form>\n                        <textarea class=\"form-control\" rows=\"2\" readonly id=\"js-pwd-result\"></textarea>\n                    </div>\n                </div>\n                <div class=\"row js-change-pwd hidden mt-3\">\n                    <div class=\"col-12\">\n                        <form class=\"form-inline\" onsubmit=\"return change_login_password(this)\" method=\"POST\" action=\"\">\n                            <input type=\"hidden\" name=\"type\" value=\"setpassword\" aria-label=\"hidden\" aria-hidden=\"true\">\n                            <div class=\"form-group mb-2\">\n                                <label for=\"inputPassword3\">Change password for <strong><?php echo fm_enc($_SESSION[FM_SESSION_ID]['logged'] ?? 'admin'); ?></strong></label>\n                            </div>\n                            <div class=\"form-group mx-sm-3 mb-2\">\n                                <label for=\"inputPassword3\" class=\"sr-only\">New password</label>\n                                <input type=\"password\" class=\"form-control btn-sm\" id=\"inputPassword3\" name=\"inputPassword3\" placeholder=\"New password\" required>\n                            </div>\n                            <div class=\"form-group mx-sm-3 mb-2\">\n                                <label for=\"inputPassword4\" class=\"sr-only\">Repeat password</label>\n                                <input type=\"password\" class=\"form-control btn-sm\" id=\"inputPassword4\" name=\"inputPassword4\" placeholder=\"Repeat password\" required>\n                            </div>\n                            <button type=\"submit\" class=\"btn btn-success btn-sm mb-2\">Save password</button>\n                        </form>\n                        <div class=\"form-control mt-2\" id=\"js-password-status\" readonly style=\"min-height:42px;\"></div>\n                    </div>\n                </div>\n            </div>\n        </div>\n    </div>\n<?php\n    fm_show_footer();\n    exit;\n}\n\n// file viewer"""
s = help_re.sub(help_new, s, count=1)

js_pwd_old = """            function show_new_pwd() {\n                $(\".js-new-pwd\").toggleClass('hidden');\n            }\n\n            // Save Settings\n"""
js_pwd_new = """            function show_new_pwd() {\n                $(\".js-new-pwd\").toggleClass('hidden');\n            }\n\n            function show_change_pwd() {\n                $(\".js-change-pwd\").toggleClass('hidden');\n            }\n\n            // Save Settings\n"""
if js_pwd_old in s:
    s = s.replace(js_pwd_old, js_pwd_new, 1)

js_hash_old = """            //Create new password hash\n            function new_password_hash($this) {\n                let form = $($this),\n                    $pwd = $(\"#js-pwd-result\");\n                $pwd.val('');\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    data: form.serialize() + \"&token=\" + window.csrf + \"&ajax=\" + true,\n                    success: function(data) {\n                        if (data) {\n                            $pwd.val(data);\n                        }\n                    }\n                });\n                return false;\n            }\n\n            // Upload files using URL @param {Object}\n"""
js_hash_new = """            //Create new password hash\n            function new_password_hash($this) {\n                let form = $($this),\n                    $pwd = $(\"#js-pwd-result\");\n                $pwd.val('');\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    data: form.serialize() + \"&token=\" + window.csrf + \"&ajax=\" + true,\n                    success: function(data) {\n                        if (data) {\n                            $pwd.val(data);\n                        }\n                    }\n                });\n                return false;\n            }\n\n            function change_login_password($this) {\n                let form = $($this),\n                    $status = $(\"#js-password-status\");\n                $status.removeClass('text-danger text-success').text('');\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    dataType: 'json',\n                    data: form.serialize() + \"&token=\" + window.csrf + \"&ajax=\" + true,\n                    success: function(data) {\n                        if (data && data.ok) {\n                            $status.addClass('text-success').text(data.message || 'Password updated');\n                            form.trigger('reset');\n                        } else {\n                            $status.addClass('text-danger').text((data && data.message) ? data.message : 'Failed to update password');\n                        }\n                    },\n                    error: function() {\n                        $status.addClass('text-danger').text('Failed to update password');\n                    }\n                });\n                return false;\n            }\n\n            // Upload files using URL @param {Object}\n"""
if js_hash_old in s:
    s = s.replace(js_hash_old, js_hash_new, 1)

pwdhash_old = """    // new password hash\n    if (isset($_POST['type']) && $_POST['type'] == \"pwdhash\") {\n        $res = isset($_POST['inputPassword2']) && !empty($_POST['inputPassword2']) ? password_hash($_POST['inputPassword2'], PASSWORD_DEFAULT) : '';\n        echo $res;\n    }\n\n    //upload using url\n"""
pwdhash_new = """    // new password hash\n    if (isset($_POST['type']) && $_POST['type'] == \"pwdhash\") {\n        $res = isset($_POST['inputPassword2']) && !empty($_POST['inputPassword2']) ? password_hash($_POST['inputPassword2'], PASSWORD_DEFAULT) : '';\n        echo $res;\n        exit();\n    }\n\n    if (isset($_POST['type']) && $_POST['type'] == \"setpassword\") {\n        $user = isset($_SESSION[FM_SESSION_ID]['logged']) ? $_SESSION[FM_SESSION_ID]['logged'] : '';\n        $newPassword = $_POST['inputPassword3'] ?? '';\n        $confirmPassword = $_POST['inputPassword4'] ?? '';\n\n        if ($user === '' || !isset($auth_users[$user])) {\n            echo json_encode(array('ok' => false, 'message' => 'Session expired'));\n            exit();\n        }\n        if (!is_string($newPassword) || strlen($newPassword) < 4) {\n            echo json_encode(array('ok' => false, 'message' => 'Password must be at least 4 characters'));\n            exit();\n        }\n        if ($newPassword !== $confirmPassword) {\n            echo json_encode(array('ok' => false, 'message' => 'Passwords do not match'));\n            exit();\n        }\n        if (!function_exists('password_hash')) {\n            echo json_encode(array('ok' => false, 'message' => 'password_hash not supported'));\n            exit();\n        }\n\n        $configFile = __DIR__ . '/config.php';\n        $configText = @file_get_contents($configFile);\n        if (!is_string($configText) || $configText === '') {\n            echo json_encode(array('ok' => false, 'message' => 'Cannot read config.php'));\n            exit();\n        }\n\n        $newHash = password_hash($newPassword, PASSWORD_DEFAULT);\n        $quotedUser = preg_quote(\"'\" . $user . \"'\", '/');\n        $count = 0;\n        $updated = preg_replace_callback(\n            \"/(\" . $quotedUser . \"\\\\s*=>\\\\s*)'[^']*'/\",\n            function ($matches) use ($newHash) {\n                return $matches[1] . var_export($newHash, true);\n            },\n            $configText,\n            1,\n            $count\n        );\n\n        if ($count !== 1 || !is_string($updated)) {\n            echo json_encode(array('ok' => false, 'message' => 'Cannot update config.php'));\n            exit();\n        }\n        if (@file_put_contents($configFile, $updated) === false) {\n            echo json_encode(array('ok' => false, 'message' => 'Cannot write config.php'));\n            exit();\n        }\n\n        $auth_users[$user] = $newHash;\n        echo json_encode(array('ok' => true, 'message' => 'Password updated and saved'));\n        exit();\n    }\n\n    //upload using url\n"""
if pwdhash_old in s:
    s = s.replace(pwdhash_old, pwdhash_new, 1)

# Final settings page override: replace the previous help/password-hash UI with a single
# account settings screen that updates login + password in config.php.
settings_page_re = re.compile(r"""if \(isset\(\$_GET\['help'\]\)\) \{.*?\n// file viewer""", re.S)
settings_page_new = """if (isset($_GET['help'])) {\n    fm_show_header(); // HEADER\n    fm_show_nav_path(FM_PATH); // current path\n?>\n\n    <div class=\"col-md-8 offset-md-2 pt-3\">\n        <div class=\"card mb-2\" data-bs-theme=\"<?php echo FM_THEME; ?>\">\n            <h6 class=\"card-header d-flex justify-content-between\">\n                <span><i class=\"fa fa-cog\"></i> Settings</span>\n                <a href=\"?p=<?php echo FM_PATH ?>\" class=\"text-danger\"><i class=\"fa fa-times-circle-o\"></i> Back</a>\n            </h6>\n            <div class=\"card-body\">\n                <div class=\"row mt-2\">\n                    <div class=\"col-12\">\n                        <form onsubmit=\"return save_account_settings(this)\" method=\"POST\" action=\"\">\n                            <input type=\"hidden\" name=\"type\" value=\"setcredentials\" aria-label=\"hidden\" aria-hidden=\"true\">\n                            <div class=\"form-group mb-3\">\n                                <label for=\"inputLogin1\">Login</label>\n                                <input type=\"text\" class=\"form-control\" id=\"inputLogin1\" name=\"inputLogin1\" value=\"<?php echo fm_enc($_SESSION[FM_SESSION_ID]['logged'] ?? 'admin'); ?>\" placeholder=\"Login\" required>\n                            </div>\n                            <div class=\"form-group mb-3\">\n                                <label for=\"inputPassword3\">New password</label>\n                                <input type=\"password\" class=\"form-control\" id=\"inputPassword3\" name=\"inputPassword3\" placeholder=\"New password\" required>\n                            </div>\n                            <div class=\"form-group mb-3\">\n                                <label for=\"inputPassword4\">Repeat password</label>\n                                <input type=\"password\" class=\"form-control\" id=\"inputPassword4\" name=\"inputPassword4\" placeholder=\"Repeat password\" required>\n                            </div>\n                            <button type=\"submit\" class=\"btn btn-success\">Save settings</button>\n                        </form>\n                        <div class=\"form-control mt-3\" id=\"js-password-status\" readonly style=\"min-height:42px;\"></div>\n                        <div class=\"mt-4 pt-3 border-top d-flex align-items-center justify-content-between flex-wrap gap-3\" style=\"border-color:#3a0a0a !important;\">\n                            <div>\n                                <div class=\"small text-muted mb-1\">Author</div>\n                                <div><strong>VADLIKE</strong></div>\n                            </div>\n                            <a href=\"https://github.com/vadlike/NanoKVM-Pro-Mount-web-manager\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"btn btn-dark\" aria-label=\"Open GitHub repository\" title=\"Open GitHub repository\" style=\"display:inline-flex;align-items:center;justify-content:center;width:52px;height:52px;border-radius:14px;\">\n                                <i class=\"fa fa-github\" style=\"font-size:28px;\"></i>\n                            </a>\n                        </div>\n                    </div>\n                </div>\n            </div>\n        </div>\n    </div>\n<?php\n    fm_show_footer();\n    exit;\n}\n\n// file viewer"""
s = settings_page_re.sub(settings_page_new, s, count=1)

js_settings_re = re.compile(r"""function show_new_pwd\(\) \{.*?// Upload files using URL @param \{Object\}""", re.S)
js_settings_new = """function save_account_settings($this) {\n                let form = $($this),\n                    $status = $(\"#js-password-status\");\n                $status.removeClass('text-danger text-success').text('');\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    dataType: 'json',\n                    data: form.serialize() + \"&token=\" + window.csrf + \"&ajax=\" + true,\n                    success: function(data) {\n                        if (data && data.ok) {\n                            $status.addClass('text-success').text(data.message || 'Settings saved');\n                            if (data.login) {\n                                form.find(\"input[name=inputLogin1]\").val(data.login);\n                            }\n                            form.find(\"input[name=inputPassword3], input[name=inputPassword4]\").val('');\n                        } else {\n                            $status.addClass('text-danger').text((data && data.message) ? data.message : 'Failed to save settings');\n                        }\n                    },\n                    error: function() {\n                        $status.addClass('text-danger').text('Failed to save settings');\n                    }\n                });\n                return false;\n            }\n\n            // Upload files using URL @param {Object}"""
s = js_settings_re.sub(js_settings_new, s, count=1)

settings_backend_re = re.compile(r"""// new password hash.*?\n\s*//upload using url""", re.S)
settings_backend_new = """if (isset($_POST['type']) && $_POST['type'] == \"setcredentials\") {\n        $currentUser = isset($_SESSION[FM_SESSION_ID]['logged']) ? $_SESSION[FM_SESSION_ID]['logged'] : '';\n        $newUser = trim($_POST['inputLogin1'] ?? '');\n        $newPassword = $_POST['inputPassword3'] ?? '';\n        $confirmPassword = $_POST['inputPassword4'] ?? '';\n\n        if ($currentUser === '' || !isset($auth_users[$currentUser])) {\n            echo json_encode(array('ok' => false, 'message' => 'Session expired'));\n            exit();\n        }\n        if (!is_string($newUser) || $newUser === '' || !preg_match('/^[A-Za-z0-9._@-]{3,64}$/', $newUser)) {\n            echo json_encode(array('ok' => false, 'message' => 'Login must be 3-64 chars: letters, digits, dot, dash, underscore, @'));\n            exit();\n        }\n        if ($newUser !== $currentUser && isset($auth_users[$newUser])) {\n            echo json_encode(array('ok' => false, 'message' => 'Login already exists'));\n            exit();\n        }\n        if (!is_string($newPassword) || strlen($newPassword) < 4) {\n            echo json_encode(array('ok' => false, 'message' => 'Password must be at least 4 characters'));\n            exit();\n        }\n        if ($newPassword !== $confirmPassword) {\n            echo json_encode(array('ok' => false, 'message' => 'Passwords do not match'));\n            exit();\n        }\n        if (!function_exists('password_hash')) {\n            echo json_encode(array('ok' => false, 'message' => 'password_hash not supported'));\n            exit();\n        }\n\n        $configFile = __DIR__ . '/config.php';\n        $configText = @file_get_contents($configFile);\n        if (!is_string($configText) || $configText === '') {\n            echo json_encode(array('ok' => false, 'message' => 'Cannot read config.php'));\n            exit();\n        }\n\n        $newHash = password_hash($newPassword, PASSWORD_DEFAULT);\n        $quotedUser = preg_quote($currentUser, '/');\n        $count = 0;\n        $updated = preg_replace_callback(\n            \"/'\" . $quotedUser . \"'\\\\s*=>\\\\s*'[^']*'/\",\n            function () use ($newUser, $newHash) {\n                return var_export($newUser, true) . ' => ' . var_export($newHash, true);\n            },\n            $configText,\n            1,\n            $count\n        );\n\n        if ($count !== 1 || !is_string($updated)) {\n            echo json_encode(array('ok' => false, 'message' => 'Cannot update config.php'));\n            exit();\n        }\n        if (@file_put_contents($configFile, $updated) === false) {\n            echo json_encode(array('ok' => false, 'message' => 'Cannot write config.php'));\n            exit();\n        }\n\n        unset($auth_users[$currentUser]);\n        $auth_users[$newUser] = $newHash;\n        $_SESSION[FM_SESSION_ID]['logged'] = $newUser;\n        echo json_encode(array('ok' => true, 'message' => 'Login and password updated', 'login' => $newUser));\n        exit();\n    }\n\n    //upload using url"""
s = settings_backend_re.sub(settings_backend_new, s, count=1)

upload_backend_re = re.compile(r"""//upload using url\s*if \(isset\(\$_POST\['type'\]\) && \$_POST\['type'\] == "upload" && !empty\(\$_REQUEST\["uploadurl"\]\)\) \{.*?\n\s*}\n\s*exit\(\);""", re.S)
upload_backend_new = """//upload using url
    if (isset($_POST['type']) && $_POST['type'] == "upload" && !empty($_REQUEST["uploadurl"])) {
        $path = FM_ROOT_PATH;
        if (FM_PATH != '') {
            $path .= '/' . FM_PATH;
        }

        function event_callback($message)
        {
            echo json_encode($message);
        }

        function get_file_path()
        {
            global $path, $fileinfo;
            return $path . "/" . basename($fileinfo->name);
        }

        function fm_nanokvm_is_public_upload_ip($ip)
        {
            if (!filter_var($ip, FILTER_VALIDATE_IP)) {
                return false;
            }

            if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) === false) {
                return false;
            }

            $blocked = array('169.254.169.254', '100.100.100.200');
            return !in_array($ip, $blocked, true);
        }

        function fm_nanokvm_resolve_upload_host($host)
        {
            $ips = array();

            if (filter_var($host, FILTER_VALIDATE_IP)) {
                $ips[] = $host;
            } else {
                if (function_exists('dns_get_record')) {
                    $records = @dns_get_record($host, DNS_A + DNS_AAAA);
                    if (is_array($records)) {
                        foreach ($records as $record) {
                            if (!empty($record['ip'])) {
                                $ips[] = $record['ip'];
                            }
                            if (!empty($record['ipv6'])) {
                                $ips[] = $record['ipv6'];
                            }
                        }
                    }
                }

                $fallback = @gethostbynamel($host);
                if (is_array($fallback)) {
                    $ips = array_merge($ips, $fallback);
                }
            }

            $ips = array_values(array_unique(array_filter($ips, 'strlen')));
            if (empty($ips)) {
                return array(false, 'Unable to resolve host');
            }

            foreach ($ips as $ip) {
                if (!fm_nanokvm_is_public_upload_ip($ip)) {
                    return array(false, 'URL is not allowed');
                }
            }

            return array(true, $ips);
        }

        function fm_nanokvm_build_redirect_url($currentUrl, $location)
        {
            $location = trim((string)$location);
            if ($location === '') {
                return false;
            }

            if (preg_match('~^https?://~i', $location)) {
                return $location;
            }

            $current = @parse_url($currentUrl);
            if (!is_array($current) || empty($current['scheme']) || empty($current['host'])) {
                return false;
            }

            $scheme = strtolower((string)$current['scheme']);
            $authority = $scheme . '://' . $current['host'];
            if (!empty($current['port'])) {
                $authority .= ':' . (int)$current['port'];
            }

            if (strpos($location, '//') === 0) {
                return $scheme . ':' . $location;
            }

            if (strpos($location, '/') === 0) {
                return $authority . $location;
            }

            $path = (string)($current['path'] ?? '/');
            $baseDir = preg_replace('~/[^/]*$~', '/', $path);
            if (!is_string($baseDir) || $baseDir === '') {
                $baseDir = '/';
            }

            return $authority . $baseDir . $location;
        }

        function fm_nanokvm_validate_upload_url($url)
        {
            $parts = @parse_url($url);
            if (!is_array($parts) || empty($parts['scheme']) || empty($parts['host'])) {
                return array(false, 'Invalid URL', null, null, null, null);
            }

            $scheme = strtolower((string)$parts['scheme']);
            if (!in_array($scheme, array('http', 'https'), true)) {
                return array(false, 'Only HTTP and HTTPS URLs are allowed', null, null, null, null);
            }

            $port = isset($parts['port']) ? (int)$parts['port'] : ($scheme === 'https' ? 443 : 80);
            $knownPorts = array(22, 23, 25, 3306);
            if ($port < 1 || $port > 65535 || in_array($port, $knownPorts, true)) {
                return array(false, 'URL port is not allowed', null, null, null, null);
            }

            list($hostOk, $resolvedOrError) = fm_nanokvm_resolve_upload_host((string)$parts['host']);
            if (!$hostOk) {
                return array(false, $resolvedOrError, null, null, null, null);
            }

            return array(true, '', $parts, $scheme, $port, $resolvedOrError);
        }

        function fm_nanokvm_apply_curl_resolve($ch, $host, $port, $ips)
        {
            if (defined('CURLOPT_RESOLVE') && is_array($ips) && !empty($ips[0])) {
                curl_setopt($ch, CURLOPT_RESOLVE, array($host . ':' . $port . ':' . $ips[0]));
            }
        }

        $url = !empty($_REQUEST["uploadurl"]) && preg_match("|^http(s)?://.+$|", stripslashes($_REQUEST["uploadurl"])) ? trim(stripslashes($_REQUEST["uploadurl"])) : null;
        if (!$url) {
            event_callback(array("fail" => array("message" => "Invalid URL")));
            exit();
        }

        if (!function_exists('curl_init')) {
            event_callback(array("fail" => array("message" => "cURL support is required")));
            exit();
        }

        $currentUrl = $url;
        $finalUrl = null;
        $finalParts = null;
        $finalPort = null;
        $finalResolvedIps = array();
        $maxRedirects = 5;

        for ($redirectIndex = 0; $redirectIndex <= $maxRedirects; $redirectIndex++) {
            list($validUrl, $validationMessage, $parts, $scheme, $port, $resolvedIps) = fm_nanokvm_validate_upload_url($currentUrl);
            if (!$validUrl) {
                event_callback(array("fail" => array("message" => $validationMessage)));
                exit();
            }

            $responseHeaders = array();
            $probe = curl_init($currentUrl);
            curl_setopt($probe, CURLOPT_NOBODY, true);
            curl_setopt($probe, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($probe, CURLOPT_HEADER, false);
            curl_setopt($probe, CURLOPT_FOLLOWLOCATION, false);
            curl_setopt($probe, CURLOPT_MAXREDIRS, 0);
            curl_setopt($probe, CURLOPT_CONNECTTIMEOUT, 10);
            curl_setopt($probe, CURLOPT_TIMEOUT, 30);
            curl_setopt($probe, CURLOPT_FAILONERROR, false);
            curl_setopt($probe, CURLOPT_USERAGENT, 'NanoKVM Pro URL Uploader');
            curl_setopt($probe, CURLOPT_HEADERFUNCTION, function ($ch, $header) use (&$responseHeaders) {
                $length = strlen($header);
                $header = trim($header);
                if ($header !== '' && strpos($header, ':') !== false) {
                    list($name, $value) = explode(':', $header, 2);
                    $responseHeaders[strtolower(trim($name))] = trim($value);
                }
                return $length;
            });
            if (defined('CURLOPT_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
                curl_setopt($probe, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
            }
            if (defined('CURLOPT_REDIR_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
                curl_setopt($probe, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
            }
            fm_nanokvm_apply_curl_resolve($probe, (string)$parts['host'], $port, $resolvedIps);

            $probeSuccess = @curl_exec($probe);
            $probeInfo = curl_getinfo($probe);
            $probeError = curl_error($probe);
            @curl_close($probe);

            if ($probeSuccess === false) {
                event_callback(array("fail" => array("message" => ($probeError !== '' ? $probeError : 'Remote probe failed'))));
                exit();
            }

            $httpCode = (int)($probeInfo["http_code"] ?? 0);
            if ($httpCode >= 300 && $httpCode < 400) {
                $location = $responseHeaders['location'] ?? '';
                $nextUrl = fm_nanokvm_build_redirect_url($currentUrl, $location);
                if ($nextUrl === false) {
                    event_callback(array("fail" => array("message" => "Invalid redirect target")));
                    exit();
                }
                $currentUrl = $nextUrl;
                continue;
            }

            if ($httpCode < 200 || $httpCode >= 300) {
                event_callback(array("fail" => array("message" => "Remote server returned HTTP " . $httpCode)));
                exit();
            }

            $finalUrl = $currentUrl;
            $finalParts = $parts;
            $finalPort = $port;
            $finalResolvedIps = $resolvedIps;
            break;
        }

        if ($finalUrl === null || !is_array($finalParts)) {
            event_callback(array("fail" => array("message" => "Too many redirects")));
            exit();
        }

        $temp_file = tempnam(sys_get_temp_dir(), "upload-");
        if ($temp_file === false) {
            event_callback(array("fail" => array("message" => "Cannot allocate temp file")));
            exit();
        }

        $fileinfo = new stdClass();
        $fileinfo->name = trim(urldecode(basename((string)($finalParts['path'] ?? $finalUrl))), ".\x00..\x20");
        if ($fileinfo->name === '') {
            $fileinfo->name = 'downloaded-file';
        }

        $allowed = (FM_UPLOAD_EXTENSION) ? explode(',', FM_UPLOAD_EXTENSION) : false;
        $ext = strtolower(pathinfo($fileinfo->name, PATHINFO_EXTENSION));
        $isFileAllowed = ($allowed) ? in_array($ext, $allowed) : true;
        if (!$isFileAllowed) {
            @unlink($temp_file);
            event_callback(array("fail" => array("message" => "File extension is not allowed")));
            exit();
        }

        $fp = @fopen($temp_file, "w");
        if ($fp === false) {
            @unlink($temp_file);
            event_callback(array("fail" => array("message" => "Cannot open temp file")));
            exit();
        }

        $ch = curl_init($finalUrl);
        curl_setopt($ch, CURLOPT_NOPROGRESS, false);
        curl_setopt($ch, CURLOPT_FOLLOWLOCATION, false);
        curl_setopt($ch, CURLOPT_MAXREDIRS, 0);
        curl_setopt($ch, CURLOPT_FILE, $fp);
        curl_setopt($ch, CURLOPT_HEADER, false);
        curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 10);
        curl_setopt($ch, CURLOPT_TIMEOUT, 300);
        curl_setopt($ch, CURLOPT_FAILONERROR, false);
        curl_setopt($ch, CURLOPT_USERAGENT, 'NanoKVM Pro URL Uploader');
        if (defined('CURLOPT_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
            curl_setopt($ch, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
        }
        if (defined('CURLOPT_REDIR_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
            curl_setopt($ch, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
        }
        fm_nanokvm_apply_curl_resolve($ch, (string)$finalParts['host'], $finalPort, $finalResolvedIps);

        $success = @curl_exec($ch);
        $curl_info = curl_getinfo($ch);
        $curl_error = curl_error($ch);
        @curl_close($ch);
        fclose($fp);

        $httpCode = (int)($curl_info["http_code"] ?? 0);
        if ($httpCode >= 300 && $httpCode < 400) {
            @unlink($temp_file);
            event_callback(array("fail" => array("message" => "Redirect changed during download is not allowed")));
            exit();
        }
        if (!$success || $httpCode < 200 || $httpCode >= 300) {
            @unlink($temp_file);
            $message = $curl_error !== '' ? $curl_error : 'Remote download failed';
            event_callback(array("fail" => array("message" => $message)));
            exit();
        }

        $fileinfo->size = $curl_info["size_download"] ?? @filesize($temp_file);
        $fileinfo->type = $curl_info["content_type"] ?? 'application/octet-stream';

        if (!@rename($temp_file, strtok(get_file_path(), '?'))) {
            @unlink($temp_file);
            event_callback(array("fail" => array("message" => "Cannot save downloaded file")));
            exit();
        }

        event_callback(array("done" => $fileinfo));
        exit();
    }
    exit();"""
s = upload_backend_re.sub(upload_backend_new, s, count=1)

torrent_backend_anchor = """    //upload using url"""
torrent_backend_block = """    if (!function_exists('fm_nanokvm_torrent_preview_dir')) {
        function fm_nanokvm_torrent_preview_dir()
        {
            return __DIR__ . '/torrent-previews';
        }
    }

    if (!function_exists('fm_nanokvm_torrent_preview_path')) {
        function fm_nanokvm_torrent_preview_path($previewId, $suffix)
        {
            return fm_nanokvm_torrent_preview_dir() . '/' . $previewId . $suffix;
        }
    }

    if (!function_exists('fm_nanokvm_torrent_preview_parse')) {
        function fm_nanokvm_torrent_preview_parse($torrentFile)
        {
            $script = __DIR__ . '/torrent-preview.py';
            if (!is_file($script)) {
                return array('ok' => false, 'message' => 'Torrent preview helper is missing');
            }

            $command = 'python3 ' . escapeshellarg($script) . ' ' . escapeshellarg($torrentFile) . ' 2>/dev/null';
            $output = @shell_exec($command);
            if (!is_string($output) || trim($output) === '') {
                return array('ok' => false, 'message' => 'Cannot parse torrent preview');
            }

            $decoded = json_decode($output, true);
            if (!is_array($decoded) || !isset($decoded['files']) || !is_array($decoded['files'])) {
                return array('ok' => false, 'message' => 'Invalid torrent preview data');
            }

            return array('ok' => true, 'data' => $decoded);
        }
    }

    if (!function_exists('fm_nanokvm_torrent_preview_create')) {
        function fm_nanokvm_torrent_preview_create($displayName, $content)
        {
            $previewDir = fm_nanokvm_torrent_preview_dir();
            if (!is_dir($previewDir) && !@mkdir($previewDir, 0775, true) && !is_dir($previewDir)) {
                return array('ok' => false, 'message' => 'Cannot create torrent preview directory');
            }

            try {
                $previewId = bin2hex(random_bytes(8));
            } catch (Throwable $e) {
                $previewId = sha1(uniqid('tp', true) . mt_rand());
            }

            $torrentPath = fm_nanokvm_torrent_preview_path($previewId, '.torrent');
            if (@file_put_contents($torrentPath, $content) === false) {
                return array('ok' => false, 'message' => 'Cannot save torrent preview');
            }

            $parsed = fm_nanokvm_torrent_preview_parse($torrentPath);
            if (!$parsed['ok']) {
                @unlink($torrentPath);
                return $parsed;
            }

            $preview = array(
                'id' => $previewId,
                'name' => ($displayName !== '' ? $displayName : (string)($parsed['data']['name'] ?? 'torrent')),
                'files' => $parsed['data']['files'],
                'createdAt' => time(),
            );

            $metaPath = fm_nanokvm_torrent_preview_path($previewId, '.json');
            if (@file_put_contents($metaPath, json_encode($preview, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) {
                @unlink($torrentPath);
                return array('ok' => false, 'message' => 'Cannot save torrent preview metadata');
            }

            return array('ok' => true, 'preview' => $preview);
        }
    }

    if (!function_exists('fm_nanokvm_torrent_preview_load')) {
        function fm_nanokvm_torrent_preview_load($previewId)
        {
            if (!preg_match('/^[A-Fa-f0-9]{16,64}$/', $previewId)) {
                return array('ok' => false, 'message' => 'Invalid torrent preview id');
            }

            $metaPath = fm_nanokvm_torrent_preview_path($previewId, '.json');
            $torrentPath = fm_nanokvm_torrent_preview_path($previewId, '.torrent');
            if (!is_file($metaPath) || !is_file($torrentPath)) {
                return array('ok' => false, 'message' => 'Torrent preview expired');
            }

            $decoded = json_decode((string)@file_get_contents($metaPath), true);
            if (!is_array($decoded) || !isset($decoded['files']) || !is_array($decoded['files'])) {
                return array('ok' => false, 'message' => 'Torrent preview is invalid');
            }

            return array('ok' => true, 'preview' => $decoded, 'torrent' => $torrentPath);
        }
    }

    if (!function_exists('fm_nanokvm_torrent_preview_delete')) {
        function fm_nanokvm_torrent_preview_delete($previewId)
        {
            @unlink(fm_nanokvm_torrent_preview_path($previewId, '.json'));
            @unlink(fm_nanokvm_torrent_preview_path($previewId, '.torrent'));
        }
    }

    if (!function_exists('fm_nanokvm_torrent_preview_cleanup_dir')) {
        function fm_nanokvm_torrent_preview_cleanup_dir($dir)
        {
            $dir = (string)$dir;
            if ($dir === '' || !is_dir($dir)) {
                return;
            }

            foreach (glob(rtrim($dir, '/') . '/*') ?: array() as $entry) {
                if (is_dir($entry)) {
                    fm_nanokvm_torrent_preview_cleanup_dir($entry);
                    @rmdir($entry);
                } else {
                    @unlink($entry);
                }
            }

            @rmdir($dir);
        }
    }

    if (!function_exists('fm_nanokvm_torrent_preview_from_magnet')) {
        function fm_nanokvm_torrent_preview_from_magnet($magnetUri)
        {
            $previewDir = fm_nanokvm_torrent_preview_dir();
            if (!is_dir($previewDir) && !@mkdir($previewDir, 0775, true) && !is_dir($previewDir)) {
                return array('ok' => false, 'message' => 'Cannot create magnet preview directory');
            }

            try {
                $metaId = bin2hex(random_bytes(8));
            } catch (Throwable $e) {
                $metaId = sha1(uniqid('tm', true) . mt_rand());
            }

            $metaDir = fm_nanokvm_torrent_preview_path($metaId, '.meta');
            if (!@mkdir($metaDir, 0775, true) && !is_dir($metaDir)) {
                return array('ok' => false, 'message' => 'Cannot create magnet metadata directory');
            }

            $options = array(
                'dir' => $metaDir,
                'seed-time' => '0',
                'seed-ratio' => '0.0',
                'bt-metadata-only' => 'true',
                'bt-save-metadata' => 'true',
                'follow-torrent' => 'false',
            );
            @fm_nanokvm_aria2_rpc('getVersion', array());
            $resp = fm_nanokvm_aria2_rpc('addUri', array(array($magnetUri), $options));
            if (
                !$resp['ok']
                && function_exists('fm_nanokvm_aria2_restart')
                && stripos((string)($resp['message'] ?? ''), 'aria2 RPC unavailable') !== false
            ) {
                fm_nanokvm_aria2_restart();
                $resp = fm_nanokvm_aria2_rpc('addUri', array(array($magnetUri), $options));
            }
            if (!$resp['ok']) {
                fm_nanokvm_torrent_preview_cleanup_dir($metaDir);
                return array('ok' => false, 'message' => $resp['message'] ?? 'Cannot start magnet metadata fetch');
            }

            $gid = (string)($resp['result'] ?? '');
            $torrentPath = '';
            $lastError = '';

            for ($attempt = 0; $attempt < 60; $attempt++) {
                $candidates = glob(rtrim($metaDir, '/') . '/*.torrent') ?: array();
                foreach ($candidates as $candidate) {
                    if (is_file($candidate) && @filesize($candidate) > 0) {
                        $torrentPath = $candidate;
                        break 2;
                    }
                }

                if ($gid !== '') {
                    $status = fm_nanokvm_aria2_rpc('tellStatus', array($gid, array('status', 'errorMessage')));
                    if (
                        empty($status['ok'])
                        && function_exists('fm_nanokvm_aria2_restart')
                        && stripos((string)($status['message'] ?? ''), 'aria2 RPC unavailable') !== false
                    ) {
                        fm_nanokvm_aria2_restart();
                        $status = fm_nanokvm_aria2_rpc('tellStatus', array($gid, array('status', 'errorMessage')));
                    }
                    if (!empty($status['ok']) && is_array($status['result'])) {
                        $taskStatus = (string)($status['result']['status'] ?? '');
                        $lastError = (string)($status['result']['errorMessage'] ?? $lastError);
                        if ($taskStatus === 'error' || $taskStatus === 'removed') {
                            break;
                        }
                    }
                }

                usleep(500000);
            }

            if ($gid !== '') {
                @fm_nanokvm_aria2_rpc('removeDownloadResult', array($gid));
            }

            if ($torrentPath === '' || !is_file($torrentPath)) {
                fm_nanokvm_torrent_preview_cleanup_dir($metaDir);
                return array('ok' => false, 'message' => ($lastError !== '' ? $lastError : 'Magnet metadata is not ready yet'));
            }

            $content = @file_get_contents($torrentPath);
            if (!is_string($content) || $content === '') {
                fm_nanokvm_torrent_preview_cleanup_dir($metaDir);
                return array('ok' => false, 'message' => 'Cannot read magnet metadata torrent file');
            }

            $preview = fm_nanokvm_torrent_preview_create(basename($torrentPath), $content);
            fm_nanokvm_torrent_preview_cleanup_dir($metaDir);
            if (!$preview['ok']) {
                return $preview;
            }

            return $preview;
        }
    }

    if (!function_exists('fm_nanokvm_torrent_source_dir')) {
        function fm_nanokvm_torrent_source_dir($basePath)
        {
            $root = (string)(realpath($basePath) ?: $basePath);
            $root = rtrim(str_replace('\\\\', '/', $root), '/');
            return $root . '/_torrent_files';
        }
    }

    if (!function_exists('fm_nanokvm_torrent_store_source')) {
        function fm_nanokvm_torrent_store_source($basePath, $preferredName, $content)
        {
            if (!is_string($content) || $content === '') {
                return array('ok' => false, 'message' => 'Empty torrent content');
            }

            $dir = fm_nanokvm_torrent_source_dir($basePath);
            if (!is_dir($dir) && !@mkdir($dir, 0775, true) && !is_dir($dir)) {
                return array('ok' => false, 'message' => 'Cannot create torrent source directory');
            }

            $name = trim((string)$preferredName);
            if ($name === '') {
                $name = 'download.torrent';
            }
            $name = basename(str_replace('\\\\', '/', $name));
            $name = preg_replace('/[^\pL\pN._ -]+/u', '_', $name);
            if (!is_string($name) || trim($name) === '' || $name === '.' || $name === '..') {
                $name = 'download.torrent';
            }
            if (strtolower(pathinfo($name, PATHINFO_EXTENSION)) !== 'torrent') {
                $name .= '.torrent';
            }

            $candidate = $dir . '/' . $name;
            $baseName = pathinfo($name, PATHINFO_FILENAME);
            $ext = pathinfo($name, PATHINFO_EXTENSION);
            $suffix = 2;
            while (is_file($candidate)) {
                $candidate = $dir . '/' . $baseName . '-' . $suffix . ($ext !== '' ? '.' . $ext : '');
                $suffix++;
            }

            if (@file_put_contents($candidate, $content) === false) {
                return array('ok' => false, 'message' => 'Cannot save torrent source file');
            }

            return array('ok' => true, 'path' => $candidate);
        }
    }

    if (!function_exists('fm_nanokvm_fetch_remote_torrent')) {
        function fm_nanokvm_fetch_remote_torrent($url)
        {
            if (!is_string($url) || trim($url) === '' || !preg_match("|^http(s)?://.+$|", $url)) {
                return array('ok' => false, 'message' => 'Only HTTP/HTTPS torrent URLs are allowed');
            }
            if (!function_exists('curl_init')) {
                return array('ok' => false, 'message' => 'cURL support is required');
            }
            if (!function_exists('fm_nanokvm_validate_upload_url') || !function_exists('fm_nanokvm_apply_curl_resolve')) {
                return array('ok' => false, 'message' => 'URL validation helpers are missing');
            }

            $currentUrl = trim($url);
            $maxRedirects = 5;
            $finalUrl = null;
            $finalParts = null;
            $finalPort = null;
            $finalResolvedIps = null;

            for ($redirectIndex = 0; $redirectIndex <= $maxRedirects; $redirectIndex++) {
                list($validUrl, $validationMessage, $parts, $scheme, $port, $resolvedIps) = fm_nanokvm_validate_upload_url($currentUrl);
                if (!$validUrl) {
                    return array('ok' => false, 'message' => $validationMessage);
                }

                $probe = curl_init($currentUrl);
                curl_setopt($probe, CURLOPT_NOBODY, true);
                curl_setopt($probe, CURLOPT_HEADER, true);
                curl_setopt($probe, CURLOPT_RETURNTRANSFER, true);
                curl_setopt($probe, CURLOPT_FOLLOWLOCATION, false);
                curl_setopt($probe, CURLOPT_MAXREDIRS, 0);
                curl_setopt($probe, CURLOPT_CONNECTTIMEOUT, 10);
                curl_setopt($probe, CURLOPT_TIMEOUT, 20);
                curl_setopt($probe, CURLOPT_FAILONERROR, false);
                curl_setopt($probe, CURLOPT_USERAGENT, 'NanoKVM Pro Torrent URL Fetcher');
                if (defined('CURLOPT_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
                    curl_setopt($probe, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
                }
                if (defined('CURLOPT_REDIR_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
                    curl_setopt($probe, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
                }
                fm_nanokvm_apply_curl_resolve($probe, (string)$parts['host'], $port, $resolvedIps);

                $probeResponse = curl_exec($probe);
                $probeInfo = curl_getinfo($probe);
                $probeError = curl_error($probe);
                curl_close($probe);

                if ($probeResponse === false) {
                    return array('ok' => false, 'message' => ($probeError !== '' ? $probeError : 'Remote probe failed'));
                }

                $httpCode = (int)($probeInfo['http_code'] ?? 0);
                if ($httpCode >= 300 && $httpCode < 400) {
                    $location = '';
                    if (preg_match('/^\s*Location:\s*(.+)$/im', (string)$probeResponse, $matches)) {
                        $location = trim($matches[1]);
                    }
                    if ($location === '') {
                        return array('ok' => false, 'message' => 'Redirect response missing Location header');
                    }
                    $nextUrl = fm_nanokvm_build_redirect_url($currentUrl, $location);
                    if ($nextUrl === null) {
                        return array('ok' => false, 'message' => 'Invalid redirect target');
                    }
                    $currentUrl = $nextUrl;
                    continue;
                }

                if ($httpCode < 200 || $httpCode >= 300) {
                    return array('ok' => false, 'message' => 'Remote server returned HTTP ' . $httpCode);
                }

                $finalUrl = $currentUrl;
                $finalParts = $parts;
                $finalPort = $port;
                $finalResolvedIps = $resolvedIps;
                break;
            }

            if ($finalUrl === null || !is_array($finalParts) || !is_array($finalResolvedIps)) {
                return array('ok' => false, 'message' => 'Too many redirects');
            }

            $ch = curl_init($finalUrl);
            curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch, CURLOPT_FOLLOWLOCATION, false);
            curl_setopt($ch, CURLOPT_MAXREDIRS, 0);
            curl_setopt($ch, CURLOPT_HEADER, false);
            curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 10);
            curl_setopt($ch, CURLOPT_TIMEOUT, 300);
            curl_setopt($ch, CURLOPT_FAILONERROR, false);
            curl_setopt($ch, CURLOPT_USERAGENT, 'NanoKVM Pro Torrent URL Fetcher');
            if (defined('CURLOPT_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
                curl_setopt($ch, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
            }
            if (defined('CURLOPT_REDIR_PROTOCOLS') && defined('CURLPROTO_HTTP') && defined('CURLPROTO_HTTPS')) {
                curl_setopt($ch, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
            }
            fm_nanokvm_apply_curl_resolve($ch, (string)$finalParts['host'], $finalPort, $finalResolvedIps);

            $content = curl_exec($ch);
            $info = curl_getinfo($ch);
            $error = curl_error($ch);
            curl_close($ch);

            if ($content === false) {
                return array('ok' => false, 'message' => ($error !== '' ? $error : 'Remote download failed'));
            }

            $httpCode = (int)($info['http_code'] ?? 0);
            if ($httpCode >= 300 && $httpCode < 400) {
                return array('ok' => false, 'message' => 'Redirect changed during download is not allowed');
            }
            if ($httpCode < 200 || $httpCode >= 300) {
                return array('ok' => false, 'message' => 'Remote server returned HTTP ' . $httpCode);
            }
            if (!is_string($content) || $content === '') {
                return array('ok' => false, 'message' => 'Downloaded torrent is empty');
            }

            $pathPart = parse_url($finalUrl, PHP_URL_PATH);
            $name = basename(is_string($pathPart) && $pathPart !== '' ? $pathPart : 'download.torrent');
            if ($name === '' || $name === '/' || $name === '.' || $name === '..') {
                $name = 'download.torrent';
            }
            if (strtolower(pathinfo($name, PATHINFO_EXTENSION)) !== 'torrent') {
                $name .= '.torrent';
            }

            return array('ok' => true, 'content' => $content, 'name' => $name);
        }
    }

    if (!function_exists('fm_nanokvm_aria2_status_fast')) {
        function fm_nanokvm_aria2_status_fast($gid)
        {
            $payload = array(
                'jsonrpc' => '2.0',
                'id' => 'nk',
                'method' => 'aria2.tellStatus',
                'params' => array($gid, array(
                    'gid',
                    'status',
                    'totalLength',
                    'completedLength',
                    'downloadSpeed',
                    'uploadSpeed',
                    'connections',
                    'numSeeders',
                    'dir',
                    'errorCode',
                    'errorMessage',
                    'files',
                    'bittorrent',
                    'followedBy',
                )),
            );
            $command = '/usr/bin/curl -sS --connect-timeout 3 --max-time 6 ';
            $command .= '-H ' . escapeshellarg('Content-Type: application/json') . ' ';
            $command .= '--data-binary ' . escapeshellarg(json_encode($payload, JSON_UNESCAPED_SLASHES)) . ' ';
            $command .= escapeshellarg('http://127.0.0.1:6800/jsonrpc');
            $response = @shell_exec($command);
            if (!is_string($response) || trim($response) === '') {
                return array('ok' => false, 'message' => 'aria2 status timeout');
            }

            $decoded = json_decode($response, true);
            if (!is_array($decoded)) {
                return array('ok' => false, 'message' => 'Invalid aria2 status response');
            }
            if (isset($decoded['error'])) {
                $message = is_array($decoded['error']) ? ($decoded['error']['message'] ?? 'aria2 status error') : 'aria2 status error';
                return array('ok' => false, 'message' => $message);
            }
            if (!isset($decoded['result']) || !is_array($decoded['result'])) {
                return array('ok' => false, 'message' => 'aria2 status missing result');
            }
            return array('ok' => true, 'result' => $decoded['result']);
        }
    }

    if (isset($_POST['type']) && $_POST['type'] == "torrent_action" && !empty($_REQUEST["gid"])) {
        $gid = trim((string)$_REQUEST["gid"]);
        $action = trim((string)($_REQUEST["torrent_action"] ?? ''));
        if ($gid === '' || !preg_match('/^[A-Fa-f0-9]+$/', $gid)) {
            echo json_encode(array("fail" => array("message" => "Invalid torrent task id")));
            exit();
        }

        $existingTask = null;
        if (function_exists('fm_nanokvm_torrent_registry_load')) {
            foreach (fm_nanokvm_torrent_registry_load(0) as $taskItem) {
                if (is_array($taskItem) && ($taskItem['gid'] ?? '') === $gid) {
                    $existingTask = $taskItem;
                    break;
                }
            }
        }

        if ($action === 'status') {
            $resp = function_exists('fm_nanokvm_aria2_status_fast')
                ? fm_nanokvm_aria2_status_fast($gid)
                : fm_nanokvm_aria2_rpc('tellStatus', array($gid));
            if (!$resp['ok']) {
                $message = (string)($resp['message'] ?? 'status refresh failed');
                $isNotFound = stripos($message, 'is not found') !== false;
                if ($isNotFound && is_array($existingTask)) {
                    $mergedTask = $existingTask;
                    $fallback = function_exists('fm_nanokvm_torrent_registry_file_progress')
                        ? fm_nanokvm_torrent_registry_file_progress($existingTask)
                        : null;

                    if (is_array($fallback)) {
                        $mergedTask['status'] = (string)($fallback['status'] ?? ($mergedTask['status'] ?? 'unknown'));
                        $mergedTask['completedLength'] = (string)($fallback['completedLength'] ?? ($mergedTask['completedLength'] ?? '0'));
                        $mergedTask['totalLength'] = (string)($fallback['totalLength'] ?? ($mergedTask['totalLength'] ?? '0'));
                        $resultMessage = $mergedTask['status'] === 'complete'
                            ? 'Status inferred from downloaded files'
                            : 'aria2 no longer tracks this task';
                    } else {
                        $mergedTask['status'] = 'missing';
                        $resultMessage = 'Task is no longer tracked by aria2';
                    }

                    if (function_exists('fm_nanokvm_torrent_registry_upsert')) {
                        fm_nanokvm_torrent_registry_upsert($mergedTask);
                    }

                    echo json_encode(array(
                        "done" => array(
                            "gid" => $gid,
                            "name" => (string)($mergedTask['name'] ?? $gid),
                            "status" => (string)($mergedTask['status'] ?? 'unknown'),
                            "progress" => (int)(is_array($fallback) ? ($fallback['progress'] ?? 0) : 0),
                            "downloadSpeed" => "0",
                            "connections" => "0",
                            "numSeeders" => "0",
                            "completedLength" => (string)($mergedTask['completedLength'] ?? '0'),
                            "totalLength" => (string)($mergedTask['totalLength'] ?? '0'),
                            "destination" => (string)($mergedTask['dir'] ?? ''),
                            "errorMessage" => $message,
                            "message" => $resultMessage
                        )
                    ));
                    exit();
                }

                echo json_encode(array("fail" => array("message" => $message)));
                exit();
            }

            $statusTask = is_array($resp['result']) ? $resp['result'] : array();
            if (!empty($statusTask['followedBy'][0]) && preg_match('/^[A-Fa-f0-9]+$/', (string)$statusTask['followedBy'][0])) {
                $nextGid = (string)$statusTask['followedBy'][0];
                $nextResp = function_exists('fm_nanokvm_aria2_status_fast')
                    ? fm_nanokvm_aria2_status_fast($nextGid)
                    : fm_nanokvm_aria2_rpc('tellStatus', array($nextGid));
                if (!empty($nextResp['ok']) && is_array($nextResp['result'])) {
                    $statusTask = $nextResp['result'];
                    $statusTask['gid'] = $nextGid;
                    if (is_array($existingTask)) {
                        $existingTask['gid'] = $nextGid;
                    }
                    if (function_exists('fm_nanokvm_torrent_registry_remove')) {
                        fm_nanokvm_torrent_registry_remove($gid);
                    }
                    $gid = $nextGid;
                }
            }
            $mergedTask = is_array($existingTask) ? $existingTask : array();
            foreach (array('gid', 'status', 'totalLength', 'completedLength', 'downloadSpeed', 'connections', 'numSeeders', 'errorMessage', 'dir', 'files', 'bittorrent', 'followedBy') as $field) {
                if (isset($statusTask[$field])) {
                    $mergedTask[$field] = $statusTask[$field];
                }
            }
            if (function_exists('fm_nanokvm_aria2_name')) {
                $resolvedName = fm_nanokvm_aria2_name(array_merge($mergedTask, $statusTask));
                $currentName = trim((string)($mergedTask['name'] ?? ''));
                if (
                    $resolvedName !== '' &&
                    $resolvedName !== 'task' &&
                    $resolvedName !== (string)($statusTask['gid'] ?? '') &&
                    (
                        $currentName === '' ||
                        stripos($currentName, 'Magnet task started') === 0 ||
                        preg_match('/^[a-f0-9]{40}\\.torrent$/i', $currentName) === 1
                    )
                ) {
                    $mergedTask['name'] = $resolvedName;
                }
            }
            if (empty($mergedTask['createdAt'])) {
                $mergedTask['createdAt'] = time();
            }
            if (function_exists('fm_nanokvm_torrent_registry_upsert')) {
                fm_nanokvm_torrent_registry_upsert($mergedTask);
            }

            echo json_encode(array(
                "done" => array(
                    "gid" => $gid,
                    "name" => function_exists('fm_nanokvm_aria2_name') ? fm_nanokvm_aria2_name($statusTask) : ($mergedTask['name'] ?? $gid),
                    "status" => (string)($statusTask['status'] ?? ($mergedTask['status'] ?? 'unknown')),
                    "progress" => (int)(function_exists('fm_nanokvm_aria2_progress') ? fm_nanokvm_aria2_progress($statusTask) : 0),
                    "downloadSpeed" => (string)($statusTask['downloadSpeed'] ?? '0'),
                    "connections" => (string)($statusTask['connections'] ?? '0'),
                    "numSeeders" => (string)($statusTask['numSeeders'] ?? '0'),
                    "completedLength" => (string)($statusTask['completedLength'] ?? '0'),
                    "totalLength" => (string)($statusTask['totalLength'] ?? '0'),
                    "destination" => (string)($statusTask['dir'] ?? ($mergedTask['dir'] ?? '')),
                    "errorMessage" => (string)($statusTask['errorMessage'] ?? ''),
                    "message" => "Status refreshed"
                )
            ));
            exit();
        }

        if ($action === 'pause') {
            $resp = array('ok' => function_exists('fm_nanokvm_aria2_enqueue') ? fm_nanokvm_aria2_enqueue(array(array('pause', array($gid)))) : false);
        } elseif ($action === 'resume') {
            $resp = array('ok' => function_exists('fm_nanokvm_aria2_enqueue') ? fm_nanokvm_aria2_enqueue(array(array('unpause', array($gid)))) : false);
        } elseif ($action === 'remove') {
            $resp = array('ok' => function_exists('fm_nanokvm_aria2_enqueue') ? fm_nanokvm_aria2_enqueue(array(
                array('forcePause', array($gid)),
                array('forceRemove', array($gid)),
                array('removeDownloadResult', array($gid)),
            )) : false);
        } else {
            echo json_encode(array("fail" => array("message" => "Unknown torrent action")));
            exit();
        }

        if (!$resp['ok']) {
            echo json_encode(array("fail" => array("message" => $resp['message'] ?? 'torrent action failed')));
            exit();
        }

        if ($action === 'remove') {
            if (function_exists('fm_nanokvm_torrent_registry_remove')) {
                fm_nanokvm_torrent_registry_remove($gid);
            }
        } elseif (function_exists('fm_nanokvm_torrent_registry_upsert') && is_array($existingTask)) {
            if (is_array($existingTask)) {
                $existingTask['status'] = $action === 'pause' ? 'paused' : 'active';
                fm_nanokvm_torrent_registry_upsert($existingTask);
            }
        }

        echo json_encode(array(
            "done" => array(
                "gid" => $gid,
                "message" => ucfirst($action) . " completed"
            )
        ));
        exit();
    }

    if (isset($_POST['type']) && $_POST['type'] == "torrent_preview_file" && !empty($_FILES["torrentfile"]["tmp_name"])) {
        $path = FM_ROOT_PATH;
        if (FM_PATH != '') {
            $path .= '/' . FM_PATH;
        }

        $upload = $_FILES["torrentfile"];
        $name = (string)($upload['name'] ?? '');
        $tmp = (string)($upload['tmp_name'] ?? '');
        if ($tmp === '' || !is_uploaded_file($tmp)) {
            echo json_encode(array("fail" => array("message" => "Invalid torrent file upload")));
            exit();
        }
        if (strtolower(pathinfo($name, PATHINFO_EXTENSION)) !== 'torrent') {
            echo json_encode(array("fail" => array("message" => "Only .torrent files are allowed")));
            exit();
        }

        $content = @file_get_contents($tmp);
        if (!is_string($content) || $content === '') {
            echo json_encode(array("fail" => array("message" => "Cannot read uploaded torrent file")));
            exit();
        }

        $preview = fm_nanokvm_torrent_preview_create($name, $content);
        if (!$preview['ok']) {
            echo json_encode(array("fail" => array("message" => $preview['message'] ?? 'Cannot preview torrent file')));
            exit();
        }

        echo json_encode(array(
            "done" => array(
                "preview_id" => $preview['preview']['id'],
                "name" => $preview['preview']['name'],
                "files" => $preview['preview']['files'],
                "message" => "Torrent preview ready"
            )
        ));
        exit();
    }

    if (isset($_POST['type']) && $_POST['type'] == "torrent_start_selected" && !empty($_REQUEST["preview_id"])) {
        $path = FM_ROOT_PATH;
        if (FM_PATH != '') {
            $path .= '/' . FM_PATH;
        }

        $previewId = trim((string)($_REQUEST["preview_id"] ?? ''));
        $loaded = fm_nanokvm_torrent_preview_load($previewId);
        if (!$loaded['ok']) {
            echo json_encode(array("fail" => array("message" => $loaded['message'] ?? 'Torrent preview expired')));
            exit();
        }

        $selectedRaw = $_REQUEST['selected_files'] ?? array();
        if (!is_array($selectedRaw)) {
            $selectedRaw = array($selectedRaw);
        }
        $selectedIndexes = array();
        foreach ($selectedRaw as $indexValue) {
            $index = (int)$indexValue;
            if ($index > 0) {
                $selectedIndexes[$index] = true;
            }
        }
        $selectedIndexes = array_keys($selectedIndexes);
        sort($selectedIndexes, SORT_NUMERIC);
        if (empty($selectedIndexes)) {
            echo json_encode(array("fail" => array("message" => "Select at least one file inside the torrent")));
            exit();
        }

        $content = @file_get_contents($loaded['torrent']);
        if (!is_string($content) || $content === '') {
            echo json_encode(array("fail" => array("message" => "Cannot read prepared torrent file")));
            exit();
        }

        $options = array(
            'dir' => (realpath($path) ?: $path),
            'seed-time' => '0',
            'seed-ratio' => '0.0',
            'bt-remove-unselected-file' => 'true',
            'follow-torrent' => 'true',
            'select-file' => implode(',', $selectedIndexes),
        );
        @fm_nanokvm_aria2_rpc('getVersion', array());
        $resp = function_exists('fm_nanokvm_aria2_add_torrent_blob')
            ? fm_nanokvm_aria2_add_torrent_blob($content, $options)
            : fm_nanokvm_aria2_rpc('addTorrent', array(base64_encode($content), array(), $options));
        if (
            !$resp['ok']
            && function_exists('fm_nanokvm_aria2_restart')
            && stripos((string)($resp['message'] ?? ''), 'aria2 RPC unavailable') !== false
        ) {
            fm_nanokvm_aria2_restart();
            $resp = function_exists('fm_nanokvm_aria2_add_torrent_blob')
                ? fm_nanokvm_aria2_add_torrent_blob($content, $options)
                : fm_nanokvm_aria2_rpc('addTorrent', array(base64_encode($content), array(), $options));
        }
        if (!$resp['ok']) {
            echo json_encode(array("fail" => array("message" => $resp['message'] ?? 'aria2 failed')));
            exit();
        }

        if (function_exists('fm_nanokvm_torrent_registry_upsert')) {
            $selectedFiles = array();
            $selectedTotal = 0;
            $resolvedDir = (string)(realpath($path) ?: $path);
            $storedSource = function_exists('fm_nanokvm_torrent_store_source')
                ? fm_nanokvm_torrent_store_source($path, (string)($loaded['preview']['name'] ?? 'torrent file'), $content)
                : array('ok' => false);
            foreach ((array)($loaded['preview']['files'] ?? array()) as $previewFile) {
                $index = (int)($previewFile['index'] ?? 0);
                if ($index <= 0 || !in_array($index, $selectedIndexes, true)) {
                    continue;
                }
                $relativePath = ltrim(str_replace('\\\\', '/', (string)($previewFile['path'] ?? '')), '/');
                $absolutePath = rtrim(str_replace('\\\\', '/', $resolvedDir), '/') . '/' . $relativePath;
                $selectedFiles[] = array(
                    'index' => $index,
                    'path' => $absolutePath,
                    'length' => (string)((int)($previewFile['length'] ?? 0)),
                );
                $selectedTotal += (int)($previewFile['length'] ?? 0);
            }
            fm_nanokvm_torrent_registry_upsert(array(
                'gid' => (string)($resp['result'] ?? ''),
                'name' => (string)($loaded['preview']['name'] ?? 'torrent file'),
                'status' => 'active',
                'dir' => '/' . trim(FM_PATH != '' ? FM_PATH : '', '/'),
                'totalLength' => (string)$selectedTotal,
                'completedLength' => 0,
                'files' => $selectedFiles,
                'sourceTorrent' => is_array($storedSource) && !empty($storedSource['ok']) ? (string)($storedSource['path'] ?? '') : '',
                'createdAt' => time(),
            ));
        }

        fm_nanokvm_torrent_preview_delete($previewId);

        echo json_encode(array(
            "done" => array(
                "name" => (string)($loaded['preview']['name'] ?? 'torrent file'),
                "gid" => $resp['result'] ?? '',
                "message" => "Selected torrent files added",
                "destination" => (('/' . trim(FM_PATH != '' ? FM_PATH : '', '/')) ?: '/'),
                "status" => "active",
                "progress" => 0,
                "completedLength" => "0",
                "totalLength" => isset($selectedTotal) ? (string)$selectedTotal : "0",
                "downloadSpeed" => "0",
                "connections" => "0",
                "numSeeders" => "0"
            )
        ));
        exit();
    }

    if (isset($_POST['type']) && $_POST['type'] == "torrent_start" && !empty($_REQUEST["torrenturl"])) {
        $path = FM_ROOT_PATH;
        if (FM_PATH != '') {
            $path .= '/' . FM_PATH;
        }

        $torrentUrl = trim((string)stripslashes($_REQUEST["torrenturl"]));
        if ($torrentUrl === '') {
            echo json_encode(array("fail" => array("message" => "Torrent URL is required")));
            exit();
        }

        $isMagnet = stripos($torrentUrl, 'magnet:?') === 0;
        $isHttp = preg_match("|^http(s)?://.+$|", $torrentUrl) === 1;
        if (!$isMagnet && !$isHttp) {
            echo json_encode(array("fail" => array("message" => "Only magnet links and HTTP/HTTPS torrent URLs are allowed")));
            exit();
        }

        $resolvedDir = (string)(realpath($path) ?: $path);
        $options = array(
            'dir' => $resolvedDir,
            'seed-time' => '0',
            'seed-ratio' => '0.0',
            'bt-remove-unselected-file' => 'true',
            'follow-torrent' => 'true',
        );
        if ($isMagnet) {
            $preview = function_exists('fm_nanokvm_torrent_preview_from_magnet')
                ? fm_nanokvm_torrent_preview_from_magnet($torrentUrl)
                : array('ok' => false, 'message' => 'Magnet preview helper is unavailable');
            if (!$preview['ok']) {
                echo json_encode(array("fail" => array("message" => $preview['message'] ?? 'Cannot prepare magnet preview')));
                exit();
            }

            echo json_encode(array(
                "done" => array(
                    "preview_id" => $preview['preview']['id'],
                    "name" => $preview['preview']['name'],
                    "files" => $preview['preview']['files'],
                    "message" => "Magnet metadata ready"
                )
            ));
            exit();
        } else {
            $downloaded = function_exists('fm_nanokvm_fetch_remote_torrent')
                ? fm_nanokvm_fetch_remote_torrent($torrentUrl)
                : array('ok' => false, 'message' => 'Torrent URL downloader is unavailable');
            if (!$downloaded['ok']) {
                echo json_encode(array("fail" => array("message" => $downloaded['message'] ?? 'Cannot fetch torrent URL')));
                exit();
            }

            $storedSource = function_exists('fm_nanokvm_torrent_store_source')
                ? fm_nanokvm_torrent_store_source($path, (string)($downloaded['name'] ?? 'download.torrent'), (string)($downloaded['content'] ?? ''))
                : array('ok' => false);
            $storedSourcePath = is_array($storedSource) && !empty($storedSource['ok']) ? (string)($storedSource['path'] ?? '') : '';

            @fm_nanokvm_aria2_rpc('getVersion', array());
            $resp = function_exists('fm_nanokvm_aria2_add_torrent_blob')
                ? fm_nanokvm_aria2_add_torrent_blob((string)($downloaded['content'] ?? ''), $options)
                : fm_nanokvm_aria2_rpc('addTorrent', array(base64_encode((string)($downloaded['content'] ?? '')), array(), $options));
            if (
                !$resp['ok']
                && function_exists('fm_nanokvm_aria2_restart')
                && stripos((string)($resp['message'] ?? ''), 'aria2 RPC unavailable') !== false
            ) {
                fm_nanokvm_aria2_restart();
                $resp = function_exists('fm_nanokvm_aria2_add_torrent_blob')
                    ? fm_nanokvm_aria2_add_torrent_blob((string)($downloaded['content'] ?? ''), $options)
                    : fm_nanokvm_aria2_rpc('addTorrent', array(base64_encode((string)($downloaded['content'] ?? '')), array(), $options));
            }
            $displayName = (string)($downloaded['name'] ?? 'download.torrent');
        }
        if (!$resp['ok']) {
            echo json_encode(array("fail" => array("message" => $resp['message'] ?? 'aria2 failed')));
            exit();
        }

        if (function_exists('fm_nanokvm_torrent_registry_upsert')) {
            fm_nanokvm_torrent_registry_upsert(array(
                'gid' => (string)($resp['result'] ?? ''),
                'name' => $displayName,
                'status' => 'active',
                'dir' => '/' . trim(FM_PATH != '' ? FM_PATH : '', '/'),
                'totalLength' => 0,
                'completedLength' => 0,
                'sourceTorrent' => $storedSourcePath,
                'createdAt' => time(),
            ));
        }

        echo json_encode(array(
            "done" => array(
                "name" => $displayName,
                "gid" => $resp['result'] ?? '',
                "message" => "Torrent download started"
            )
        ));
        exit();
    }

    //upload using url"""
s = s.replace(torrent_backend_anchor, torrent_backend_block, 1)

upload_url_tab_old = """                    <li class="nav-item">\n                        <a class="nav-link" href="#urlUploader" class="js-url-upload" data-target="#urlUploader"><i class="fa fa-link"></i> <?php echo lng('Upload from URL') ?></a>\n                    </li>\n"""
upload_url_tab_new = """                    <li class="nav-item">\n                        <a class="nav-link" href="#urlUploader" class="js-url-upload" data-target="#urlUploader"><i class="fa fa-link"></i> <?php echo lng('Upload from URL') ?></a>\n                    </li>\n                    <li class="nav-item">\n                        <a class="nav-link" href="#torrentUploader" data-target="#torrentUploader"><i class="fa fa-magnet"></i> Download Torrent</a>\n                    </li>\n"""
s = s.replace(upload_url_tab_old, upload_url_tab_new, 1)

upload_url_panel_old = """                <div class="upload-url-wrapper card-tabs-container hidden" id="urlUploader">\n                    <form id="js-form-url-upload" class="row row-cols-lg-auto g-3 align-items-center" onsubmit="return upload_from_url(this);" method="POST" action="">\n                        <input type="hidden" name="type" value="upload" aria-label="hidden" aria-hidden="true">\n                        <input type="url" placeholder="URL" name="uploadurl" required class="form-control" style="width: 80%">\n                        <input type="hidden" name="token" value="<?php echo $_SESSION['token']; ?>">\n                        <button type="submit" class="btn btn-primary ms-3"><?php echo lng('Upload') ?></button>\n                        <div class="lds-facebook">\n                            <div></div>\n                            <div></div>\n                            <div></div>\n                        </div>\n                    </form>\n                    <div id="js-url-upload__list" class="col-9 mt-3"></div>\n                </div>\n"""
upload_url_panel_new = """                <div class="upload-url-wrapper card-tabs-container hidden" id="urlUploader">\n                    <form id="js-form-url-upload" class="row row-cols-lg-auto g-3 align-items-center" onsubmit="return upload_from_url(this);" method="POST" action="">\n                        <input type="hidden" name="type" value="upload" aria-label="hidden" aria-hidden="true">\n                        <input type="url" placeholder="URL" name="uploadurl" required class="form-control" style="width: 80%">\n                        <input type="hidden" name="token" value="<?php echo $_SESSION['token']; ?>">\n                        <button type="submit" class="btn btn-primary ms-3"><?php echo lng('Upload') ?></button>\n                        <div class="lds-facebook">\n                            <div></div>\n                            <div></div>\n                            <div></div>\n                        </div>\n                    </form>\n                    <div id="js-url-upload__list" class="col-9 mt-3"></div>\n                </div>\n\n                <div class="upload-url-wrapper card-tabs-container hidden" id="torrentUploader">\n                    <?php $torrentTasks = function_exists('fm_nanokvm_aria2_tasks') ? fm_nanokvm_aria2_tasks(12) : array(); ?>\n                    <?php $torrentDestination = '/' . trim(FM_PATH != '' ? FM_PATH : '', '/'); ?>\n                    <?php $torrentFilesFolder = ($torrentDestination !== '/' ? $torrentDestination : '') . '/_torrent_files'; ?>\n                    <div class=\"alert alert-dark border mb-3\">\n                        <div><strong>Torrent destination:</strong> <?php echo fm_enc($torrentDestination !== '/' ? $torrentDestination : '/'); ?></div>\n                        <div class=\"small text-muted mt-1\"><strong>Torrent files folder:</strong> <?php echo fm_enc($torrentFilesFolder); ?></div>\n                    </div>\n                    <form id="js-form-torrent-upload" class="row row-cols-lg-auto g-3 align-items-center" onsubmit="return start_torrent_download(this);" method="POST" action="">\n                        <input type="hidden" name="type" value="torrent_start" aria-label=\"hidden\" aria-hidden=\"true\">\n                        <input type="text" placeholder="Magnet link or direct .torrent URL" name="torrenturl" required class="form-control" style="width: 80%">\n                        <input type="hidden" name="token" value="<?php echo $_SESSION['token']; ?>">\n                        <button type="submit" class="btn btn-primary ms-3">Start direct</button>\n                        <div class="lds-facebook">\n                            <div></div>\n                            <div></div>\n                            <div></div>\n                        </div>\n                    </form>\n                    <form id=\"js-form-torrent-file\" class=\"row row-cols-lg-auto g-3 align-items-center mt-3\" onsubmit=\"return start_torrent_file_upload(this);\" method=\"POST\" action=\"\" enctype=\"multipart/form-data\">\n                        <input type=\"hidden\" name=\"type\" value=\"torrent_preview_file\" aria-label=\"hidden\" aria-hidden=\"true\">\n                        <input type=\"file\" name=\"torrentfile\" accept=\".torrent,application/x-bittorrent\" required class=\"form-control\" style=\"width: 80%\">\n                        <input type=\"hidden\" name=\"token\" value=\"<?php echo $_SESSION['token']; ?>\">\n                        <button type=\"submit\" class=\"btn btn-primary ms-3\">Preview .torrent</button>\n                        <div class=\"lds-facebook\">\n                            <div></div>\n                            <div></div>\n                            <div></div>\n                        </div>\n                    </form>\n                    <div id=\"js-torrent-preview\" class=\"col-12 mt-3 hidden\">\n                        <div class=\"alert alert-dark border mb-0\">\n                            <div class=\"d-flex justify-content-between align-items-center flex-wrap gap-2 mb-3\">\n                                <div>\n                                    <strong id=\"js-torrent-preview-name\">Torrent preview</strong>\n                                    <div class=\"small text-muted\" id=\"js-torrent-preview-summary\"></div>\n                                </div>\n                                <div class=\"d-flex gap-2 flex-wrap\">\n                                    <button type=\"button\" class=\"btn btn-outline-light btn-sm js-torrent-preview-select-all\">Select all</button>\n                                    <button type=\"button\" class=\"btn btn-outline-secondary btn-sm js-torrent-preview-clear\">Clear</button>\n                                </div>\n                            </div>\n                            <form id=\"js-form-torrent-selected\" onsubmit=\"return start_selected_torrent_download(this);\" method=\"POST\" action=\"\">\n                                <input type=\"hidden\" name=\"type\" value=\"torrent_start_selected\" aria-label=\"hidden\" aria-hidden=\"true\">\n                                <input type=\"hidden\" name=\"preview_id\" value=\"\">\n                                <input type=\"hidden\" name=\"token\" value=\"<?php echo $_SESSION['token']; ?>\">\n                                <div id=\"js-torrent-preview-files\" class=\"mb-3\"></div>\n                                <div class=\"d-flex gap-2 flex-wrap align-items-center\">\n                                    <button type=\"submit\" class=\"btn btn-success\">Download selected</button>\n                                    <button type=\"button\" class=\"btn btn-outline-danger js-torrent-preview-cancel\">Cancel</button>\n                                    <div class=\"lds-facebook\">\n                                        <div></div>\n                                        <div></div>\n                                        <div></div>\n                                    </div>\n                                </div>\n                            </form>\n                        </div>\n                    </div>\n                    <div id="js-torrent-download__list" class="col-12 mt-3"></div>\n                    <div class=\"col-12 mt-4\">\n                        <h6 class=\"mb-3\">Recent Torrent Tasks</h6>\n                        <?php if (!empty($torrentTasks)): ?>\n                            <?php foreach ($torrentTasks as $task): ?>\n                                <?php $taskStatus = (string)($task['status'] ?? 'unknown'); ?>\n                                <?php $taskGid = (string)($task['gid'] ?? ''); ?>\n                                <?php $taskPath = (string)($task['files'][0]['path'] ?? ''); ?>\n                                <?php $taskDestination = (string)($task['dir'] ?? ''); ?>\n                                <?php if ($taskDestination === '' && $taskPath !== '') { $taskDestination = dirname($taskPath); } ?>\n                                <?php if ($taskDestination === '.' || $taskDestination === '') { $taskDestination = ($torrentDestination !== '/' ? $torrentDestination : '/'); } ?>\n                                <div class=\"alert alert-dark border mb-2\">\n                                    <div><strong><?php echo fm_enc(function_exists('fm_nanokvm_aria2_name') ? fm_nanokvm_aria2_name($task) : ($taskGid !== '' ? $taskGid : 'task')); ?></strong></div>\n                                    <div>Status: <?php echo fm_enc($taskStatus); ?> | Progress: <?php echo (int)(function_exists('fm_nanokvm_aria2_progress') ? fm_nanokvm_aria2_progress($task) : 0); ?>%</div>\n                                    <div class=\"small text-muted mb-2\">Destination: <?php echo fm_enc($taskDestination !== '' ? $taskDestination : ($torrentDestination !== '' ? $torrentDestination : FM_ROOT_PATH)); ?></div>\n                                    <div class=\"d-flex gap-2 flex-wrap\">\n                                        <?php if (in_array($taskStatus, array('active', 'waiting'), true)): ?>\n                                            <button type=\"button\" class=\"btn btn-warning btn-sm js-torrent-action\" data-action=\"pause\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Pause</button>\n                                        <?php endif; ?>\n                                        <?php if ($taskStatus === 'paused'): ?>\n                                            <button type=\"button\" class=\"btn btn-success btn-sm js-torrent-action\" data-action=\"resume\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Resume</button>\n                                        <?php endif; ?>\n                                        <button type=\"button\" class=\"btn btn-danger btn-sm js-torrent-action\" data-action=\"remove\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Remove</button>\n                                    </div>\n                                </div>\n                            <?php endforeach; ?>\n                        <?php else: ?>\n                            <div class=\"alert alert-dark border mb-0\">No torrent tasks yet.</div>\n                        <?php endif; ?>\n                    </div>\n                </div>\n"""
s = s.replace(upload_url_panel_old, upload_url_panel_new, 1)
s = s.replace(
    """                                    <div class=\"small text-muted mb-2\">GID: <?php echo fm_enc($taskGid); ?></div>\n""",
    ""
)

torrent_render_old = """                        <?php if (!empty($torrentTasks)): ?>\n                            <?php foreach ($torrentTasks as $task): ?>\n                                <?php $taskStatus = (string)($task['status'] ?? 'unknown'); ?>\n"""
torrent_render_new = """                        <?php if (!empty($torrentTasks)): ?>\n                            <?php foreach ($torrentTasks as $task): ?>\n                                <?php $taskProgressData = function_exists('fm_nanokvm_torrent_registry_file_progress') ? fm_nanokvm_torrent_registry_file_progress($task) : null; ?>\n                                <?php if (is_array($taskProgressData)) { $task = array_merge($task, $taskProgressData); } ?>\n                                <?php $taskStatus = (string)($task['status'] ?? 'unknown'); ?>\n"""
if torrent_render_old in s and "taskProgressData" not in s:
    s = s.replace(torrent_render_old, torrent_render_new, 1)

torrent_destination_marker = """<?php $torrentTasks = function_exists('fm_nanokvm_aria2_tasks') ? fm_nanokvm_aria2_tasks(12) : array(); ?>\n                    <form id="js-form-torrent-upload" class="row row-cols-lg-auto g-3 align-items-center" onsubmit="return start_torrent_download(this);" method="POST" action="">"""
torrent_destination_insert = """<?php $torrentTasks = function_exists('fm_nanokvm_aria2_tasks') ? fm_nanokvm_aria2_tasks(12) : array(); ?>\n                    <?php $torrentDestination = '/' . trim(FM_PATH != '' ? FM_PATH : '', '/'); ?>\n                    <div class=\"alert alert-dark border mb-3\">\n                        <strong>Torrent destination:</strong> <?php echo fm_enc($torrentDestination !== '/' ? $torrentDestination : '/'); ?>\n                    </div>\n                    <form id="js-form-torrent-upload" class="row row-cols-lg-auto g-3 align-items-center" onsubmit="return start_torrent_download(this);" method="POST" action="">"""
if torrent_destination_marker in s and "Torrent destination:" not in s:
    s = s.replace(torrent_destination_marker, torrent_destination_insert, 1)

torrent_task_marker = """<?php $taskStatus = (string)($task['status'] ?? 'unknown'); ?>\n                                <?php $taskGid = (string)($task['gid'] ?? ''); ?>\n                                <div class=\"alert alert-dark border mb-2\">"""
torrent_task_insert = """<?php $taskStatus = (string)($task['status'] ?? 'unknown'); ?>\n                                <?php $taskGid = (string)($task['gid'] ?? ''); ?>\n                                <?php $taskPath = (string)($task['files'][0]['path'] ?? ''); ?>\n                                <?php $taskDestination = (string)($task['dir'] ?? ''); ?>\n                                <?php if ($taskDestination === '' && $taskPath !== '') { $taskDestination = dirname($taskPath); } ?>\n                                <?php if ($taskDestination === '.' || $taskDestination === '') { $taskDestination = ($torrentDestination !== '/' ? $torrentDestination : '/'); } ?>\n                                <div class=\"alert alert-dark border mb-2\">"""
if torrent_task_marker in s and "$taskDestination" not in s:
    s = s.replace(torrent_task_marker, torrent_task_insert, 1)

torrent_gid_marker = """<div class=\"small text-muted mb-2\">GID: <?php echo fm_enc($taskGid); ?></div>"""
torrent_gid_insert = """<div class=\"small text-muted\">Destination: <?php echo fm_enc($taskDestination !== '' ? $taskDestination : ($torrentDestination !== '' ? $torrentDestination : FM_ROOT_PATH)); ?></div>"""
if torrent_gid_marker in s and "Destination:" not in s:
    s = s.replace(torrent_gid_marker, torrent_gid_insert, 1)

torrent_card_old = """<div class=\"alert alert-dark border mb-2\">\n                                    <div><strong><?php echo fm_enc(function_exists('fm_nanokvm_aria2_name') ? fm_nanokvm_aria2_name($task) : ($taskGid !== '' ? $taskGid : 'task')); ?></strong></div>\n                                    <div>Status: <?php echo fm_enc($taskStatus); ?> | Progress: <?php echo (int)(function_exists('fm_nanokvm_aria2_progress') ? fm_nanokvm_aria2_progress($task) : 0); ?>%</div>\n                                    <div class=\"small text-muted mb-2\">Destination: <?php echo fm_enc($taskDestination !== '' ? $taskDestination : ($torrentDestination !== '' ? $torrentDestination : FM_ROOT_PATH)); ?></div>\n                                    <div class=\"d-flex gap-2 flex-wrap\">\n                                        <?php if (in_array($taskStatus, array('active', 'waiting'), true)): ?>\n                                            <button type=\"button\" class=\"btn btn-warning btn-sm js-torrent-action\" data-action=\"pause\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Pause</button>\n                                        <?php endif; ?>\n                                        <?php if ($taskStatus === 'paused'): ?>\n                                            <button type=\"button\" class=\"btn btn-success btn-sm js-torrent-action\" data-action=\"resume\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Resume</button>\n                                        <?php endif; ?>\n                                        <button type=\"button\" class=\"btn btn-danger btn-sm js-torrent-action\" data-action=\"remove\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Remove</button>\n                                    </div>\n                                </div>"""
torrent_card_new = """<div class=\"alert alert-dark border mb-2 js-torrent-card\" data-torrent-gid=\"<?php echo fm_enc($taskGid); ?>\">\n                                    <?php $taskCompleted = (string)($task['completedLength'] ?? '0'); ?>\n                                    <?php $taskTotal = (string)($task['totalLength'] ?? '0'); ?>\n                                    <?php $taskSpeed = (string)($task['downloadSpeed'] ?? '0'); ?>\n                                    <?php $taskConnections = (string)($task['connections'] ?? '0'); ?>\n                                    <?php $taskSeeders = (string)($task['numSeeders'] ?? '0'); ?>\n                                    <div><strong class=\"js-torrent-name\"><?php echo fm_enc(function_exists('fm_nanokvm_aria2_name') ? fm_nanokvm_aria2_name($task) : ($taskGid !== '' ? $taskGid : 'task')); ?></strong></div>\n                                    <div>Status: <span class=\"js-torrent-status\"><?php echo fm_enc($taskStatus); ?></span> | Progress: <span class=\"js-torrent-progress\"><?php echo (int)(function_exists('fm_nanokvm_aria2_progress') ? fm_nanokvm_aria2_progress($task) : 0); ?></span>%</div>\n                                    <div class=\"small text-muted js-torrent-live-meta\">Downloaded: <?php echo fm_enc(function_exists('fm_nanokvm_bytes_human') ? fm_nanokvm_bytes_human($taskCompleted) : $taskCompleted); ?> / <?php echo fm_enc(function_exists('fm_nanokvm_bytes_human') ? fm_nanokvm_bytes_human($taskTotal) : $taskTotal); ?><?php if ((float)$taskSpeed > 0): ?> | Speed: <?php echo fm_enc(function_exists('fm_nanokvm_bytes_human') ? fm_nanokvm_bytes_human($taskSpeed) : $taskSpeed); ?>/s<?php endif; ?> | Connections: <?php echo fm_enc($taskConnections); ?><?php if ((int)$taskSeeders > 0): ?> | Seeders: <?php echo fm_enc($taskSeeders); ?><?php endif; ?></div>\n                                    <div class=\"small text-muted js-torrent-destination mb-2\">Destination: <?php echo fm_enc($taskDestination !== '' ? $taskDestination : ($torrentDestination !== '' ? $torrentDestination : FM_ROOT_PATH)); ?></div>\n                                    <div class=\"d-flex gap-2 flex-wrap js-torrent-controls\">\n                                        <button type=\"button\" class=\"btn btn-secondary btn-sm js-torrent-action\" data-action=\"status\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Refresh</button>\n                                        <?php if (in_array($taskStatus, array('active', 'waiting'), true)): ?>\n                                            <button type=\"button\" class=\"btn btn-warning btn-sm js-torrent-action\" data-action=\"pause\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Pause</button>\n                                        <?php endif; ?>\n                                        <?php if ($taskStatus === 'paused'): ?>\n                                            <button type=\"button\" class=\"btn btn-success btn-sm js-torrent-action\" data-action=\"resume\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Resume</button>\n                                        <?php endif; ?>\n                                        <button type=\"button\" class=\"btn btn-danger btn-sm js-torrent-action\" data-action=\"remove\" data-gid=\"<?php echo fm_enc($taskGid); ?>\">Remove</button>\n                                    </div>\n                                </div>"""
if torrent_card_old in s:
    s = s.replace(torrent_card_old, torrent_card_new, 1)

js_torrent_anchor = """            // Upload files using URL @param {Object}\n"""
js_torrent_new = """            function torrent_safe_json(data) {\n                if (!data) {\n                    return null;\n                }\n                if (typeof data === 'object') {\n                    return data;\n                }\n                try {\n                    return JSON.parse(data);\n                } catch (error) {\n                    return null;\n                }\n            }\n\n            function torrent_escape_html(value) {\n                return String(value || '').replace(/[&<>\\\"']/g, function(chr) {\n                    return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '\\\"': '&quot;', \"'\": '&#39;' })[chr] || chr;\n                });\n            }\n\n            function torrent_format_bytes(value) {\n                let bytes = parseInt(value, 10);\n                if (!isFinite(bytes) || bytes <= 0) {\n                    return '0 B';\n                }\n                let units = ['B', 'KB', 'MB', 'GB', 'TB'];\n                let unitIndex = 0;\n                while (bytes >= 1024 && unitIndex < units.length - 1) {\n                    bytes = bytes / 1024;\n                    unitIndex += 1;\n                }\n                return (unitIndex === 0 ? Math.round(bytes) : bytes.toFixed(bytes >= 100 ? 0 : 1)) + ' ' + units[unitIndex];\n            }\n\n            function torrent_build_tree(files) {\n                let root = { type: 'dir', name: '', children: {} };\n                (files || []).forEach(function(file) {\n                    let cleanPath = String(file.path || '').replace(/^\\/+/,'').replace(/\\/+/g, '/'),\n                        parts = cleanPath.split('/').filter(Boolean),\n                        current = root;\n                    if (!parts.length) {\n                        parts = ['file-' + (file.index || '0')];\n                    }\n                    parts.forEach(function(part, idx) {\n                        let isLeaf = idx === parts.length - 1;\n                        if (isLeaf) {\n                            current.children[part] = {\n                                type: 'file',\n                                name: part,\n                                index: parseInt(file.index, 10) || 0,\n                                path: cleanPath || part,\n                                length: parseInt(file.length, 10) || 0\n                            };\n                        } else {\n                            if (!current.children[part]) {\n                                current.children[part] = { type: 'dir', name: part, children: {} };\n                            }\n                            current = current.children[part];\n                        }\n                    });\n                });\n                return root;\n            }\n\n            function torrent_count_files(node) {\n                if (!node) {\n                    return 0;\n                }\n                if (node.type === 'file') {\n                    node.fileCount = 1;\n                    return 1;\n                }\n                let total = 0;\n                Object.keys(node.children || {}).forEach(function(key) {\n                    total += torrent_count_files(node.children[key]);\n                });\n                node.fileCount = total;\n                return total;\n            }\n\n            function torrent_render_tree(node, depth, state) {\n                if (!node) {\n                    return '';\n                }\n                if (node.type === 'file') {\n                    let checkboxId = 'torrent-file-' + node.index;\n                    return '<label class=\"d-flex justify-content-between gap-3 align-items-center border rounded px-3 py-2 mb-2\" for=\"' + checkboxId + '\">' +\n                        '<span class=\"d-flex align-items-center gap-2\">' +\n                        '<input class=\"form-check-input mt-0\" type=\"checkbox\" name=\"selected_files[]\" value=\"' + node.index + '\" id=\"' + checkboxId + '\" checked>' +\n                        '<span>' + torrent_escape_html(node.name) + '</span>' +\n                        '</span>' +\n                        '<span class=\"small text-muted text-nowrap\">' + torrent_escape_html(torrent_format_bytes(node.length)) + '</span>' +\n                        '</label>';\n                }\n\n                let entries = Object.keys(node.children || {}).map(function(key) { return node.children[key]; });\n                entries.sort(function(a, b) {\n                    if (a.type !== b.type) {\n                        return a.type === 'dir' ? -1 : 1;\n                    }\n                    return String(a.name || '').localeCompare(String(b.name || ''), undefined, { sensitivity: 'base', numeric: true });\n                });\n\n                let nodeId = 'torrent-dir-' + (++state.counter),\n                    childrenHtml = entries.map(function(child) { return torrent_render_tree(child, depth + 1, state); }).join(''),\n                    detailsAttr = depth < 2 ? ' open' : '';\n\n                return '<details class=\"js-torrent-tree-node border rounded px-3 py-2 mb-2\" data-node=\"' + nodeId + '\"' + detailsAttr + '>' +\n                    '<summary class=\"d-flex justify-content-between align-items-center gap-3\" style=\"cursor:pointer; list-style:none;\">' +\n                    '<label class=\"d-flex align-items-center gap-2 mb-0\" onclick=\"event.stopPropagation();\">' +\n                    '<input class=\"form-check-input mt-0 js-torrent-folder-toggle\" type=\"checkbox\" data-node=\"' + nodeId + '\" checked>' +\n                    '<span class=\"fw-semibold\">' + torrent_escape_html(node.name || 'Folder') + '</span>' +\n                    '</label>' +\n                    '<span class=\"small text-muted text-nowrap\">' + (node.fileCount || 0) + ' files</span>' +\n                    '</summary>' +\n                    '<div class=\"js-torrent-tree-children ms-4 mt-2\">' + childrenHtml + '</div>' +\n                    '</details>';\n            }\n\n            function torrent_sync_folder_states() {\n                $($('#js-torrent-preview-files .js-torrent-tree-node').get().reverse()).each(function() {\n                    let node = $(this),\n                        fileChecks = node.find('input[name=\"selected_files[]\"]'),\n                        folderToggle = node.find('> summary .js-torrent-folder-toggle').first(),\n                        checkedCount = fileChecks.filter(':checked').length;\n                    if (!folderToggle.length || !fileChecks.length) {\n                        return;\n                    }\n                    folderToggle.prop('indeterminate', checkedCount > 0 && checkedCount < fileChecks.length);\n                    folderToggle.prop('checked', checkedCount > 0);\n                });\n            }\n\n            function hide_torrent_preview() {\n                $('#js-torrent-preview').addClass('hidden');\n                $('#js-form-torrent-selected').trigger('reset');\n                $('#js-torrent-preview-files').empty();\n                $('#js-torrent-preview-name').text('Torrent preview');\n                $('#js-torrent-preview-summary').text('');\n            }\n\n            function render_torrent_preview(payload) {\n                let preview = $('#js-torrent-preview'),\n                    form = $('#js-form-torrent-selected'),\n                    fileList = $('#js-torrent-preview-files'),\n                    name = payload && payload.name ? payload.name : 'Torrent preview',\n                    files = payload && Array.isArray(payload.files) ? payload.files : [],\n                    tree = torrent_build_tree(files),\n                    state = { counter: 0 },\n                    html = '';\n                form.find('input[name=preview_id]').val(payload && payload.preview_id ? payload.preview_id : '');\n                $('#js-torrent-preview-name').text(name);\n                $('#js-torrent-preview-summary').text(files.length + ' files available for download');\n                torrent_count_files(tree);\n                Object.keys(tree.children || {}).sort(function(a, b) {\n                    let left = tree.children[a], right = tree.children[b];\n                    if (left.type !== right.type) {\n                        return left.type === 'dir' ? -1 : 1;\n                    }\n                    return String(left.name || '').localeCompare(String(right.name || ''), undefined, { sensitivity: 'base', numeric: true });\n                }).forEach(function(key) {\n                    html += torrent_render_tree(tree.children[key], 0, state);\n                });\n                fileList.html(html);\n                preview.removeClass('hidden');\n                torrent_sync_folder_states();\n            }\n\n            function start_torrent_download($this) {\n                let form = $($this),\n                    resultWrapper = $(\"div#js-torrent-download__list\");\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    data: form.serialize() + \"&token=\" + window.csrf + \"&ajax=\" + true,\n                    beforeSend: function() {\n                        form.find(\"input[name=torrenturl]\").attr(\"disabled\", \"disabled\");\n                        form.find(\"button\").hide();\n                        form.find(\".lds-facebook\").addClass('show-me');\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent started') + '</div>');\n                            form.find(\"input[name=torrenturl]\").val('');\n                            setTimeout(function() { window.location.reload(); }, 700);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                        }\n                        form.find(\"input[name=torrenturl]\").removeAttr(\"disabled\");\n                        form.find(\"button\").show();\n                        form.find(\".lds-facebook\").removeClass('show-me');\n                    },\n                    error: function(xhr) {\n                        form.find(\"input[name=torrenturl]\").removeAttr(\"disabled\");\n                        form.find(\"button\").show();\n                        form.find(\".lds-facebook\").removeClass('show-me');\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            }\n\n            function start_torrent_file_upload($this) {\n                let form = $($this),\n                    resultWrapper = $(\"div#js-torrent-download__list\"),\n                    formData = new FormData($this);\n                formData.append('token', window.csrf);\n                formData.append('ajax', true);\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    data: formData,\n                    processData: false,\n                    contentType: false,\n                    beforeSend: function() {\n                        form.find(\"input[name=torrentfile]\").attr(\"disabled\", \"disabled\");\n                        form.find(\"button\").hide();\n                        form.find(\".lds-facebook\").addClass('show-me');\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent preview ready') + '</div>');\n                            render_torrent_preview(payload.done);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                        }\n                        form.find(\"input[name=torrentfile]\").removeAttr(\"disabled\");\n                        form.find(\"button\").show();\n                        form.find(\".lds-facebook\").removeClass('show-me');\n                    },\n                    error: function(xhr) {\n                        form.find(\"input[name=torrentfile]\").removeAttr(\"disabled\");\n                        form.find(\"button\").show();\n                        form.find(\".lds-facebook\").removeClass('show-me');\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            }\n\n            function start_selected_torrent_download($this) {\n                let form = $($this),\n                    resultWrapper = $(\"div#js-torrent-download__list\");\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    data: form.serialize() + \"&token=\" + window.csrf + \"&ajax=\" + true,\n                    beforeSend: function() {\n                        form.find(\"input, button\").attr(\"disabled\", \"disabled\");\n                        form.find(\".lds-facebook\").addClass('show-me');\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent started') + '</div>');\n                            hide_torrent_preview();\n                            $('#js-form-torrent-file').trigger('reset');\n                            setTimeout(function() { window.location.reload(); }, 700);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                        }\n                        form.find(\".lds-facebook\").removeClass('show-me');\n                    },\n                    error: function(xhr) {\n                        resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: torrent start failed</div>');\n                        form.find(\"input, button\").removeAttr(\"disabled\");\n                        form.find(\".lds-facebook\").removeClass('show-me');\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            }\n\n            $(document).on('change', '.js-torrent-folder-toggle', function() {\n                let toggle = $(this),\n                    node = toggle.closest('.js-torrent-tree-node'),\n                    isChecked = toggle.is(':checked');\n                toggle.prop('indeterminate', false);\n                node.find('input[name=\"selected_files[]\"]').prop('checked', isChecked);\n                node.find('.js-torrent-folder-toggle').not(toggle).prop('checked', isChecked).prop('indeterminate', false);\n                torrent_sync_folder_states();\n            });\n\n            $(document).on('change', '#js-torrent-preview-files input[name=\"selected_files[]\"]', function() {\n                torrent_sync_folder_states();\n            });\n\n            $(document).on('click', '.js-torrent-preview-select-all', function() {\n                $('#js-torrent-preview-files input[name=\"selected_files[]\"]').prop('checked', true);\n                $('#js-torrent-preview-files .js-torrent-folder-toggle').prop('checked', true).prop('indeterminate', false);\n            });\n\n            $(document).on('click', '.js-torrent-preview-clear', function() {\n                $('#js-torrent-preview-files input[name=\"selected_files[]\"]').prop('checked', false);\n                $('#js-torrent-preview-files .js-torrent-folder-toggle').prop('checked', false).prop('indeterminate', false);\n            });\n\n            $(document).on('click', '.js-torrent-preview-cancel', function() {\n                hide_torrent_preview();\n            });\n\n            $(document).on('click', '.js-torrent-action', function() {\n                let button = $(this),\n                    gid = button.data('gid'),\n                    action = button.data('action'),\n                    resultWrapper = $(\"div#js-torrent-download__list\");\n                if (!gid || !action) {\n                    return false;\n                }\n                button.prop('disabled', true);\n                $.ajax({\n                    type: 'POST',\n                    url: window.location.href,\n                    data: {\n                        type: 'torrent_action',\n                        torrent_action: action,\n                        gid: gid,\n                        token: window.csrf,\n                        ajax: true\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Action completed') + '</div>');\n                            setTimeout(function() { window.location.reload(); }, 500);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            button.prop('disabled', false);\n                        }\n                    },\n                    error: function(xhr) {\n                        resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: torrent action failed</div>');\n                        button.prop('disabled', false);\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            });\n\n            // Upload files using URL @param {Object}\n"""
s = s.replace(js_torrent_anchor, js_torrent_new, 1)

tab_state_anchor = """            function torrent_safe_json(data) {\n"""
tab_state_block = """            function nk_upload_tab_key() {\n                return 'nanokvm-pro-upload-tab';\n            }\n\n            function nk_normalize_upload_tab(target) {\n                let allowed = ['#fileUploader', '#urlUploader', '#torrentUploader'];\n                return allowed.indexOf(target) !== -1 ? target : '#fileUploader';\n            }\n\n            function nk_upload_tab_query_value(target) {\n                let normalized = nk_normalize_upload_tab(target);\n                if (normalized === '#urlUploader') {\n                    return 'url';\n                }\n                if (normalized === '#torrentUploader') {\n                    return 'torrent';\n                }\n                return 'files';\n            }\n\n            function nk_query_value_to_upload_tab(value) {\n                value = String(value || '').toLowerCase();\n                if (value === 'url') {\n                    return '#urlUploader';\n                }\n                if (value === 'torrent') {\n                    return '#torrentUploader';\n                }\n                return '#fileUploader';\n            }\n\n            function nk_set_upload_tab(target, syncHash) {\n                let normalized = nk_normalize_upload_tab(target);\n                try {\n                    window.sessionStorage.setItem(nk_upload_tab_key(), normalized);\n                } catch (error) {\n                }\n                if (syncHash === true) {\n                    let nextUrl = null;\n                    try {\n                        let url = new URL(window.location.href);\n                        url.searchParams.set('upload_tab', nk_upload_tab_query_value(normalized));\n                        url.hash = normalized;\n                        nextUrl = url.pathname + url.search + url.hash;\n                    } catch (error) {\n                    }\n                    if (nextUrl && window.history && typeof window.history.replaceState === 'function') {\n                        window.history.replaceState(null, '', nextUrl);\n                    } else {\n                        window.location.hash = normalized;\n                    }\n                }\n                return normalized;\n            }\n\n            function nk_get_upload_tab() {\n                let hash = window.location.hash || '',\n                    stored = '',\n                    queryTarget = '';\n                try {\n                    let url = new URL(window.location.href),\n                        uploadTab = url.searchParams.get('upload_tab') || '';\n                    if (uploadTab) {\n                        queryTarget = nk_query_value_to_upload_tab(uploadTab);\n                    }\n                } catch (error) {\n                }\n                try {\n                    stored = window.sessionStorage.getItem(nk_upload_tab_key()) || '';\n                } catch (error) {\n                }\n                if (hash) {\n                    return nk_normalize_upload_tab(hash);\n                }\n                if (queryTarget) {\n                    return nk_normalize_upload_tab(queryTarget);\n                }\n                if (stored) {\n                    return nk_normalize_upload_tab(stored);\n                }\n                return '#fileUploader';\n            }\n\n            function nk_restore_upload_tab() {\n                let target = nk_get_upload_tab(),\n                    panel = $(target),\n                    link = $('.nav-tabs .nav-link[data-target=\"' + target + '\"]').first();\n                if (!panel.length) {\n                    return;\n                }\n                nk_set_upload_tab(target, true);\n                $('.card-tabs-container').addClass('hidden');\n                panel.removeClass('hidden');\n                $('.nav-tabs .nav-link').removeClass('active');\n                if (link.length) {\n                    link.addClass('active');\n                }\n            }\n\n            $(function() {\n                if ($('#fileUploader, #urlUploader, #torrentUploader').length) {\n                    nk_restore_upload_tab();\n                }\n            });\n\n            $(document).on('click', '.nav-tabs .nav-link[data-target]', function() {\n                let target = $(this).attr('data-target') || $(this).attr('href') || '';\n                if (/^#(?:fileUploader|urlUploader|torrentUploader)$/.test(target)) {\n                    nk_set_upload_tab(target, true);\n                }\n            });\n\n            function torrent_safe_json(data) {\n"""
if tab_state_anchor in s and "function nk_upload_tab_key()" not in s:
    s = s.replace(tab_state_anchor, tab_state_block, 1)

s = s.replace(
    """                            setTimeout(function() { window.location.reload(); }, 700);\n""",
    """                            nk_set_upload_tab('#torrentUploader', true);\n                            setTimeout(function() { window.location.reload(); }, 700);\n"""
)
s = s.replace(
    """                            render_torrent_preview(payload.done);\n""",
    """                            nk_set_upload_tab('#torrentUploader', true);\n                            render_torrent_preview(payload.done);\n"""
)
s = s.replace(
    """                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent started') + '</div>');\n                            form.find(\"input[name=torrenturl]\").val('');\n                            nk_set_upload_tab('#torrentUploader', true);\n                            setTimeout(function() { window.location.reload(); }, 700);\n                        } else if (payload && payload['fail']) {\n""",
    """                        if (payload && payload.done && payload.done.preview_id && Array.isArray(payload.done.files)) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent preview ready') + '</div>');\n                            form.find(\"input[name=torrenturl]\").val('');\n                            nk_set_upload_tab('#torrentUploader', true);\n                            render_torrent_preview(payload.done);\n                        } else if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent started') + '</div>');\n                            form.find(\"input[name=torrenturl]\").val('');\n                            nk_set_upload_tab('#torrentUploader', true);\n                            setTimeout(function() { window.location.reload(); }, 700);\n                        } else if (payload && payload['fail']) {\n"""
)
s = s.replace(
    """                            setTimeout(function() { window.location.reload(); }, 500);\n""",
    """                            nk_set_upload_tab('#torrentUploader', true);\n                            setTimeout(function() { window.location.reload(); }, 500);\n"""
)

torrent_action_old = """            $(document).on('click', '.js-torrent-action', function() {\n                let button = $(this),\n                    gid = button.data('gid'),\n                    action = button.data('action'),\n                    resultWrapper = $(\"div#js-torrent-download__list\");\n                if (!gid || !action) {\n                    return false;\n                }\n                button.prop('disabled', true);\n                $.ajax({\n                    type: 'POST',\n                    url: window.location.href,\n                    data: {\n                        type: 'torrent_action',\n                        torrent_action: action,\n                        gid: gid,\n                        token: window.csrf,\n                        ajax: true\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Action completed') + '</div>');\n                            setTimeout(function() { window.location.reload(); }, 500);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            button.prop('disabled', false);\n                        }\n                    },\n                    error: function(xhr) {\n                        resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: torrent action failed</div>');\n                        button.prop('disabled', false);\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            });\n\n            // Upload files using URL @param {Object}\n"""
torrent_action_new = """            function torrent_render_controls(gid, status) {\n                let html = '<button type=\"button\" class=\"btn btn-secondary btn-sm js-torrent-action\" data-action=\"status\" data-gid=\"' + gid + '\">Refresh</button>';\n                if (status === 'active' || status === 'waiting') {\n                    html += '<button type=\"button\" class=\"btn btn-warning btn-sm js-torrent-action\" data-action=\"pause\" data-gid=\"' + gid + '\">Pause</button>';\n                }\n                if (status === 'paused') {\n                    html += '<button type=\"button\" class=\"btn btn-success btn-sm js-torrent-action\" data-action=\"resume\" data-gid=\"' + gid + '\">Resume</button>';\n                }\n                html += '<button type=\"button\" class=\"btn btn-danger btn-sm js-torrent-action\" data-action=\"remove\" data-gid=\"' + gid + '\">Remove</button>';\n                return html;\n            }\n\n            function torrent_should_poll(status) {\n                status = String(status || '').toLowerCase();\n                return status === 'active' || status === 'waiting';\n            }\n\n            function torrent_update_card(card, payload) {\n                let gid = card.data('torrent-gid') || payload.gid || '',\n                    status = String(payload.status || 'unknown'),\n                    progress = parseInt(payload.progress || 0, 10) || 0,\n                    downloadSpeed = parseInt(payload.downloadSpeed || 0, 10) || 0,\n                    connections = parseInt(payload.connections || 0, 10) || 0,\n                    seeders = parseInt(payload.numSeeders || 0, 10) || 0,\n                    completedLength = parseInt(payload.completedLength || 0, 10) || 0,\n                    totalLength = parseInt(payload.totalLength || 0, 10) || 0,\n                    destination = payload.destination || '';\n                if (payload.name) {\n                    card.find('.js-torrent-name').text(payload.name);\n                }\n                card.find('.js-torrent-status').text(status);\n                card.find('.js-torrent-progress').text(progress);\n                card.attr('data-torrent-status', status.toLowerCase());\n                if (destination) {\n                    card.find('.js-torrent-destination').text('Destination: ' + destination);\n                }\n                let meta = 'Downloaded: ' + torrent_format_bytes(completedLength) + ' / ' + torrent_format_bytes(totalLength);\n                if (downloadSpeed > 0) {\n                    meta += ' | Speed: ' + torrent_format_bytes(downloadSpeed) + '/s';\n                }\n                meta += ' | Connections: ' + connections;\n                if (seeders > 0) {\n                    meta += ' | Seeders: ' + seeders;\n                }\n                if (payload.errorMessage) {\n                    meta += ' | ' + payload.errorMessage;\n                }\n                card.find('.js-torrent-live-meta').text(meta);\n                card.find('.js-torrent-controls').html(torrent_render_controls(gid, status));\n            }\n\n            function torrent_request_status(card, silent) {\n                let gid = card.data('torrent-gid'),\n                    resultWrapper = $(\"div#js-torrent-download__list\"),\n                    refreshButton = card.find('.js-torrent-action[data-action=\"status\"]').first();\n                if (!gid || card.data('torrentLoading') === true) {\n                    return;\n                }\n                card.data('torrentLoading', true);\n                refreshButton.prop('disabled', true);\n                $.ajax({\n                    type: 'POST',\n                    url: window.location.href,\n                    data: {\n                        type: 'torrent_action',\n                        torrent_action: 'status',\n                        gid: gid,\n                        token: window.csrf,\n                        ajax: true\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            torrent_update_card(card, payload.done);\n                        } else if (!silent && payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                        }\n                    },\n                    error: function(xhr) {\n                        if (!silent) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: status refresh failed</div>');\n                        }\n                        console.error(xhr);\n                    },\n                    complete: function() {\n                        card.data('torrentLoading', false);\n                        card.find('.js-torrent-action[data-action=\"status\"]').prop('disabled', false);\n                    }\n                });\n            }\n\n            function torrent_poll_visible_cards() {\n                if (document.hidden) {\n                    return;\n                }\n                $('.js-torrent-card').each(function() {\n                    let card = $(this),\n                        currentStatus = String(card.attr('data-torrent-status') || $.trim(card.find('.js-torrent-status').text()) || '').toLowerCase();\n                    if (torrent_should_poll(currentStatus)) {\n                        torrent_request_status(card, true);\n                    }\n                });\n            }\n\n            $(function() {\n                $('.js-torrent-card').each(function(index) {\n                    let card = $(this),\n                        currentStatus = $.trim(card.find('.js-torrent-status').text()).toLowerCase();\n                    card.attr('data-torrent-status', currentStatus);\n                    if (currentStatus === '' || ['active', 'waiting', 'paused', 'complete', 'unknown'].indexOf(currentStatus) !== -1) {\n                        setTimeout(function() { torrent_request_status(card, true); }, index * 180);\n                    }\n                });\n                window.nanokvmTorrentPollTimer = window.setInterval(torrent_poll_visible_cards, 5000);\n                $(document).on('visibilitychange', function() {\n                    if (!document.hidden) {\n                        torrent_poll_visible_cards();\n                    }\n                });\n            });\n\n            $(document).on('click', '.js-torrent-action', function() {\n                let button = $(this),\n                    gid = button.data('gid'),\n                    action = button.data('action'),\n                    card = button.closest('.js-torrent-card'),\n                    resultWrapper = $(\"div#js-torrent-download__list\");\n                if (!gid || !action) {\n                    return false;\n                }\n                if (action === 'status') {\n                    torrent_request_status(card, false);\n                    return false;\n                }\n                button.prop('disabled', true);\n                $.ajax({\n                    type: 'POST',\n                    url: window.location.href,\n                    data: {\n                        type: 'torrent_action',\n                        torrent_action: action,\n                        gid: gid,\n                        token: window.csrf,\n                        ajax: true\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Action completed') + '</div>');\n                            setTimeout(function() { window.location.reload(); }, 500);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            button.prop('disabled', false);\n                        }\n                    },\n                    error: function(xhr) {\n                        resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: torrent action failed</div>');\n                        button.prop('disabled', false);\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            });\n\n            // Upload files using URL @param {Object}\n"""
if torrent_action_old in s and "function torrent_render_controls" not in s:
    s = s.replace(torrent_action_old, torrent_action_new, 1)

torrent_action_old_with_tab = """            $(document).on('click', '.js-torrent-action', function() {\n                let button = $(this),\n                    gid = button.data('gid'),\n                    action = button.data('action'),\n                    resultWrapper = $(\"div#js-torrent-download__list\");\n                if (!gid || !action) {\n                    return false;\n                }\n                button.prop('disabled', true);\n                $.ajax({\n                    type: 'POST',\n                    url: window.location.href,\n                    data: {\n                        type: 'torrent_action',\n                        torrent_action: action,\n                        gid: gid,\n                        token: window.csrf,\n                        ajax: true\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Action completed') + '</div>');\n                            nk_set_upload_tab('#torrentUploader', true);\n                            setTimeout(function() { window.location.reload(); }, 500);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            button.prop('disabled', false);\n                        }\n                    },\n                    error: function(xhr) {\n                        resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: torrent action failed</div>');\n                        button.prop('disabled', false);\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            });\n\n            // Upload files using URL @param {Object}\n"""
if torrent_action_old_with_tab in s and "function torrent_render_controls" not in s:
    s = s.replace(torrent_action_old_with_tab, torrent_action_new, 1)

help_link_old = """<a title="<?php echo lng('Help') ?>" class="dropdown-item nav-link" href="?p=<?php echo urlencode(FM_PATH) ?>&amp;help=2"><i class="fa fa-exclamation-circle" aria-hidden="true"></i> <?php echo lng('Help') ?></a>"""
help_link_new = """<a title="Settings" class="dropdown-item nav-link" href="?p=<?php echo urlencode(FM_PATH) ?>&amp;help=2"><i class="fa fa-cog" aria-hidden="true"></i> Settings</a>"""
s = s.replace(help_link_old, help_link_new)

file_row_old = """                <tr>\n                    <?php if (!FM_READONLY): ?>\n                        <td class=\"custom-checkbox-td\">\n                            <div class=\"custom-control custom-checkbox\">\n                                <input type=\"checkbox\" class=\"custom-control-input\" id=\"<?php echo $ik ?>\" name=\"file[]\" value=\"<?php echo fm_enc($f) ?>\">\n"""
file_row_new = """                <tr<?php\n                    $mountable = preg_match('/\\.(iso|img|bin|raw|dd|ima|dsk|vfd|efi|vhd|vhdx|cue|mdf|mds|vmdk|qcow2|dmg)$/i', $f) === 1;\n                    $mountPath = '/' . trim((FM_PATH != '' ? FM_PATH . '/' : '') . $f, '/');\n                    static $mountedInfo = null;\n                    if ($mountedInfo === null) {\n                        $mountedInfo = function_exists('fm_nanokvm_mounted_image') ? fm_nanokvm_mounted_image() : array('file' => '', 'cdrom' => false, 'readOnly' => false);\n                    }\n                    $isMountedCurrent = $mountable && (($mountedInfo['file'] ?? '') === $mountPath);\n                    echo $isMountedCurrent ? ' style=\"box-shadow: inset 4px 0 0 #24a148; background: rgba(36,161,72,0.08);\"' : '';\n                ?>>\n                    <?php if (!FM_READONLY): ?>\n                        <td class=\"custom-checkbox-td\">\n                            <div class=\"custom-control custom-checkbox\">\n                                <input type=\"checkbox\" class=\"custom-control-input\" id=\"<?php echo $ik ?>\" name=\"file[]\" value=\"<?php echo fm_enc($f) ?>\">\n"""
if file_row_old in s and "$mountable = preg_match('/\\.(iso|img|bin|raw|dd|ima|dsk|vfd|efi|vhd|vhdx|cue|mdf|mds|vmdk|qcow2|dmg)$/i', $f) === 1;" not in s:
    s = s.replace(file_row_old, file_row_new, 1)

action_re = re.compile(r"""                        <a title=\"<\?php echo lng\('DirectLink'\) \?>\" href=\"<\?php echo fm_enc\(FM_ROOT_URL \. \(FM_PATH != '' \? '/' \. FM_PATH : ''\) \. '/' \. \$f\) \?>\" target=\"_blank\"><i class=\"fa fa-link\"></i></a>\n                        <a title=\"<\?php echo lng\('Download'\) \?>\" href=\"\?p=<\?php echo urlencode\(FM_PATH\) \?>&amp;dl=<\?php echo urlencode\(\$f\) \?>\" onclick=\"confirmDailog\(event, 1211, '<\?php echo lng\('Download'\); \?>','<\?php echo urlencode\(\$f\); \?>', this.href\);\"><i class=\"fa fa-download\"></i></a>\n""")
action_new = """                        <?php if ($mountable): ?>\n                            <?php $returnUrl = FM_SELF_URL . '?p=' . urlencode(FM_PATH); ?>\n                            <?php $mountBase = 'mount-image.php?action=mount&file=' . urlencode($mountPath) . '&return=' . urlencode($returnUrl); ?>\n                            <?php if ($isMountedCurrent): ?>\n                                <span class=\"badge bg-success me-1\"><?php echo !empty($mountedInfo['cdrom']) ? 'Mounted CD' : 'Mounted USB'; ?></span>\n                            <?php endif; ?>\n                            <a href=\"<?php echo fm_enc($mountBase . '&cdrom=1&read_only=1'); ?>\" title=\"Mount CD-ROM\" class=\"btn btn-xs btn-outline-primary py-0 px-1 me-1\">CD</a>\n                            <a href=\"<?php echo fm_enc($mountBase . '&cdrom=0&read_only=0'); ?>\" title=\"Mount Mass Storage\" class=\"btn btn-xs btn-outline-success py-0 px-1 me-1\">USB</a>\n                            <?php if ($isMountedCurrent): ?>\n                                <a href=\"<?php echo fm_enc('mount-image.php?action=unmount&return=' . urlencode($returnUrl)); ?>\" title=\"Unmount\" class=\"btn btn-xs btn-outline-danger py-0 px-1 me-1\">Unmount</a>\n                            <?php endif; ?>\n                        <?php endif; ?>\n                        <a title=\"<?php echo lng('DirectLink') ?>\" href=\"mount-image.php?action=raw&amp;file=<?php echo urlencode($mountPath) ?>\" target=\"_blank\"><i class=\"fa fa-link\"></i></a>\n                        <a title=\"<?php echo lng('Download') ?>\" href=\"?p=<?php echo urlencode(FM_PATH) ?>&amp;dl=<?php echo urlencode($f) ?>\" onclick=\"confirmDailog(event, 1211, '<?php echo lng('Download'); ?>','<?php echo urlencode($f); ?>', this.href);\"><i class=\"fa fa-download\"></i></a>\n"""
s = action_re.sub(action_new, s, count=1)

raw_route_anchor = "// Download\n"
raw_route_block = """// Direct Link\nif (isset($_GET['raw'])) {\n    $raw = urldecode($_GET['raw']);\n    $raw = ltrim(fm_clean_path($raw), '/');\n    $raw = str_replace('..', '', $raw);\n    $parts = explode('/', $raw, 2);\n    $rootEntry = $parts[0] ?? '';\n    $fullPath = FM_ROOT_PATH . '/' . $raw;\n    $realBase = $rootEntry !== '' ? realpath(FM_ROOT_PATH . '/' . $rootEntry) : false;\n    $realFile = realpath($fullPath);\n    $basePrefix = $realBase !== false ? rtrim(str_replace('\\\\', '/', $realBase), '/') . '/' : '';\n    $filePath = $realFile !== false ? str_replace('\\\\', '/', $realFile) : '';\n\n    if (\n        $raw !== '' &&\n        $realBase !== false &&\n        $realFile !== false &&\n        is_file($realFile) &&\n        ($filePath === str_replace('\\\\', '/', $realBase) || strpos($filePath, $basePrefix) === 0)\n    ) {\n        if (fm_nanokvm_stream_inline($realFile, basename($realFile))) {\n            exit;\n        }\n    }\n\n    fm_set_msg(lng('File not found'), 'error');\n    $FM_PATH = FM_PATH;\n    fm_redirect(FM_SELF_URL . '?p=' . urlencode($FM_PATH));\n}\n\n// Download\n"""
if raw_route_anchor in s and "if (isset($_GET['raw']))" not in s:
    s = s.replace(raw_route_anchor, raw_route_block, 1)

exclude_helper_old = """function fm_is_exclude_items($name, $path)\n{\n    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));\n    if (isset($exclude_items) and sizeof($exclude_items)) {\n        unset($exclude_items);\n    }\n\n    $exclude_items = FM_EXCLUDE_ITEMS;\n    if (version_compare(PHP_VERSION, '7.0.0', '<')) {\n        $exclude_items = unserialize($exclude_items);\n    }\n    if (!in_array($name, $exclude_items) && !in_array(\"*.$ext\", $exclude_items) && !in_array($path, $exclude_items)) {\n        return true;\n    }\n    return false;\n}\n"""
exclude_helper_new = """function fm_is_exclude_items($name, $path)\n{\n    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));\n    if (preg_match('/\\.aria2$/i', $name) === 1) {\n        return false;\n    }\n    if (preg_match('/^[a-f0-9]{40}\\.torrent$/i', $name) === 1) {\n        return false;\n    }\n    if (isset($exclude_items) and sizeof($exclude_items)) {\n        unset($exclude_items);\n    }\n\n    $exclude_items = FM_EXCLUDE_ITEMS;\n    if (version_compare(PHP_VERSION, '7.0.0', '<')) {\n        $exclude_items = unserialize($exclude_items);\n    }\n    if (!in_array($name, $exclude_items) && !in_array(\"*.$ext\", $exclude_items) && !in_array($path, $exclude_items)) {\n        return true;\n    }\n    return false;\n}\n"""
if exclude_helper_old in s and "preg_match('/^[a-f0-9]{40}\\\\.torrent$/i', $name) === 1" not in s:
    s = s.replace(exclude_helper_old, exclude_helper_new, 1)

selected_download_success_old = """                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent started') + '</div>');\n                            hide_torrent_preview();\n                            $('#js-form-torrent-file').trigger('reset');\n                            setTimeout(function() { window.location.reload(); }, 700);\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                        }\n                        form.find(\".lds-facebook\").removeClass('show-me');\n"""
selected_download_success_new = """                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent started') + '</div>');\n                            hide_torrent_preview();\n                            $('#js-form-torrent-file').trigger('reset');\n                            nk_set_upload_tab('#torrentUploader', true);\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                            form.find(\".lds-facebook\").removeClass('show-me');\n                            let gid = payload.done.gid || '',\n                                taskName = payload.done.name || 'Torrent task',\n                                destination = payload.done.destination || '/',\n                                connections = parseInt(payload.done.connections || 0, 10) || 0,\n                                totalLength = parseInt(payload.done.totalLength || 0, 10) || 0,\n                                completedLength = parseInt(payload.done.completedLength || 0, 10) || 0,\n                                downloadSpeed = parseInt(payload.done.downloadSpeed || 0, 10) || 0,\n                                seeders = parseInt(payload.done.numSeeders || 0, 10) || 0,\n                                meta = 'Downloaded: ' + torrent_format_bytes(completedLength) + ' / ' + torrent_format_bytes(totalLength);\n                            if (downloadSpeed > 0) {\n                                meta += ' | Speed: ' + torrent_format_bytes(downloadSpeed) + '/s';\n                            }\n                            meta += ' | Connections: ' + connections;\n                            if (seeders > 0) {\n                                meta += ' | Seeders: ' + seeders;\n                            }\n                            if (gid) {\n                                let existingCard = $('.js-torrent-card[data-torrent-gid=\"' + gid + '\"]').first();\n                                if (!existingCard.length) {\n                                    $('#torrentUploader .col-12.mt-4 .alert.alert-dark.border.mb-0').filter(function() {\n                                        return $(this).text().indexOf('No torrent tasks yet.') !== -1;\n                                    }).remove();\n                                    let cardHtml = '<div class=\"alert alert-dark border mb-2 js-torrent-card\" data-torrent-gid=\"' + torrent_escape_html(gid) + '\" data-torrent-status=\"active\">' +\n                                        '<div><strong class=\"js-torrent-name\">' + torrent_escape_html(taskName) + '</strong></div>' +\n                                        '<div>Status: <span class=\"js-torrent-status\">active</span> | Progress: <span class=\"js-torrent-progress\">0</span>%</div>' +\n                                        '<div class=\"small text-muted js-torrent-live-meta\">' + torrent_escape_html(meta) + '</div>' +\n                                        '<div class=\"small text-muted js-torrent-destination mb-2\">Destination: ' + torrent_escape_html(destination) + '</div>' +\n                                        '<div class=\"d-flex gap-2 flex-wrap js-torrent-controls\">' + torrent_render_controls(gid, 'active') + '</div>' +\n                                        '</div>';\n                                    let firstCard = $('#torrentUploader .js-torrent-card').first(),\n                                        tasksContainer = $('#torrentUploader .col-12.mt-4');\n                                    if (firstCard.length) {\n                                        firstCard.before(cardHtml);\n                                    } else if (tasksContainer.length) {\n                                        tasksContainer.append(cardHtml);\n                                    }\n                                    existingCard = $('.js-torrent-card[data-torrent-gid=\"' + gid + '\"]').first();\n                                }\n                                if (existingCard.length) {\n                                    setTimeout(function() { torrent_request_status(existingCard, true); }, 800);\n                                }\n                            }\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                            form.find(\".lds-facebook\").removeClass('show-me');\n                        } else {\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                            form.find(\".lds-facebook\").removeClass('show-me');\n                        }\n"""
if selected_download_success_old in s and "torrent_render_controls(gid, 'active')" not in s:
    s = s.replace(selected_download_success_old, selected_download_success_new, 1)

selected_download_re = re.compile(
    r"""            function start_selected_torrent_download\(\$this\) \{\n.*?(?=            \$\(document\)\.on\('change', '\.js-torrent-folder-toggle')""",
    re.S
)
selected_download_rewrite = """            function start_selected_torrent_download($this) {\n                let form = $($this),\n                    resultWrapper = $(\"div#js-torrent-download__list\");\n                $.ajax({\n                    type: form.attr('method'),\n                    url: form.attr('action'),\n                    data: form.serialize() + \"&token=\" + window.csrf + \"&ajax=\" + true,\n                    beforeSend: function() {\n                        form.find(\"input, button\").attr(\"disabled\", \"disabled\");\n                        form.find(\".lds-facebook\").addClass('show-me');\n                    },\n                    success: function(data) {\n                        let payload = torrent_safe_json(data);\n                        if (payload && payload.done) {\n                            resultWrapper.prepend('<div class=\"alert alert-success row\">' + (payload.done.message || 'Torrent started') + '</div>');\n                            hide_torrent_preview();\n                            $('#js-form-torrent-file').trigger('reset');\n                            nk_set_upload_tab('#torrentUploader', true);\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                            form.find(\".lds-facebook\").removeClass('show-me');\n                            let gid = payload.done.gid || '',\n                                taskName = payload.done.name || 'Torrent task',\n                                destination = payload.done.destination || '/',\n                                connections = parseInt(payload.done.connections || 0, 10) || 0,\n                                totalLength = parseInt(payload.done.totalLength || 0, 10) || 0,\n                                completedLength = parseInt(payload.done.completedLength || 0, 10) || 0,\n                                downloadSpeed = parseInt(payload.done.downloadSpeed || 0, 10) || 0,\n                                seeders = parseInt(payload.done.numSeeders || 0, 10) || 0,\n                                meta = 'Downloaded: ' + torrent_format_bytes(completedLength) + ' / ' + torrent_format_bytes(totalLength);\n                            if (downloadSpeed > 0) {\n                                meta += ' | Speed: ' + torrent_format_bytes(downloadSpeed) + '/s';\n                            }\n                            meta += ' | Connections: ' + connections;\n                            if (seeders > 0) {\n                                meta += ' | Seeders: ' + seeders;\n                            }\n                            if (gid) {\n                                let existingCard = $('.js-torrent-card[data-torrent-gid=\"' + gid + '\"]').first();\n                                if (!existingCard.length) {\n                                    $('#torrentUploader .col-12.mt-4 .alert.alert-dark.border.mb-0').filter(function() {\n                                        return $(this).text().indexOf('No torrent tasks yet.') !== -1;\n                                    }).remove();\n                                    let cardHtml = '<div class=\"alert alert-dark border mb-2 js-torrent-card\" data-torrent-gid=\"' + torrent_escape_html(gid) + '\" data-torrent-status=\"active\">' +\n                                        '<div><strong class=\"js-torrent-name\">' + torrent_escape_html(taskName) + '</strong></div>' +\n                                        '<div>Status: <span class=\"js-torrent-status\">active</span> | Progress: <span class=\"js-torrent-progress\">0</span>%</div>' +\n                                        '<div class=\"small text-muted js-torrent-live-meta\">' + torrent_escape_html(meta) + '</div>' +\n                                        '<div class=\"small text-muted js-torrent-destination mb-2\">Destination: ' + torrent_escape_html(destination) + '</div>' +\n                                        '<div class=\"d-flex gap-2 flex-wrap js-torrent-controls\">' + torrent_render_controls(gid, 'active') + '</div>' +\n                                        '</div>';\n                                    let firstCard = $('#torrentUploader .js-torrent-card').first(),\n                                        tasksContainer = $('#torrentUploader .col-12.mt-4');\n                                    if (firstCard.length) {\n                                        firstCard.before(cardHtml);\n                                    } else if (tasksContainer.length) {\n                                        tasksContainer.append(cardHtml);\n                                    }\n                                    existingCard = $('.js-torrent-card[data-torrent-gid=\"' + gid + '\"]').first();\n                                }\n                                if (existingCard.length) {\n                                    setTimeout(function() { torrent_request_status(existingCard, true); }, 800);\n                                }\n                            }\n                        } else if (payload && payload['fail']) {\n                            resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: ' + payload.fail.message + '</div>');\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                            form.find(\".lds-facebook\").removeClass('show-me');\n                        } else {\n                            form.find(\"input, button\").removeAttr(\"disabled\");\n                            form.find(\".lds-facebook\").removeClass('show-me');\n                        }\n                    },\n                    error: function(xhr) {\n                        resultWrapper.prepend('<div class=\"alert alert-danger row\">Error: torrent start failed</div>');\n                        form.find(\"input, button\").removeAttr(\"disabled\");\n                        form.find(\".lds-facebook\").removeClass('show-me');\n                        console.error(xhr);\n                    }\n                });\n                return false;\n            }\n"""
s = selected_download_re.sub(selected_download_rewrite, s, count=1)

p.write_text(s, encoding="utf-8")
PY
ln -sfn "${APP_FILE}" "${INDEX_FILE}"

cat > "${ARIA2_CONFIG_FILE}" <<EOF
dir=/data
enable-rpc=true
rpc-listen-all=false
rpc-listen-port=6800
rpc-allow-origin-all=false
continue=true
bt-save-metadata=true
rpc-save-upload-metadata=false
seed-time=0
seed-ratio=0
file-allocation=none
max-concurrent-downloads=3
max-connection-per-server=8
summary-interval=0
console-log-level=warn
log-level=warn
input-file=${ARIA2_SESSION_FILE}
save-session=${ARIA2_SESSION_FILE}
save-session-interval=30
daemon=false
EOF
touch "${ARIA2_SESSION_FILE}"

for base in /sdcard /data; do
  if [[ -d "${base}" ]]; then
    mkdir -p "${base}/_torrent_files"
    find "${base}" -maxdepth 1 -type f -regextype posix-extended -iregex '.*/[0-9a-f]{40}\.torrent' -print0 2>/dev/null | while IFS= read -r -d '' file; do
      mv -f "${file}" "${base}/_torrent_files/" 2>/dev/null || true
    done
  fi
done

if curl -sS -H 'Content-Type: application/json' --data-binary '{"jsonrpc":"2.0","id":"nk","method":"aria2.tellActive","params":[["gid"]]}' http://127.0.0.1:6800/jsonrpc 2>/dev/null | grep -q '"result":\[\]'; then
  for base in /sdcard /data; do
    if [[ -d "${base}" ]]; then
      find "${base}" -maxdepth 1 -type f -name '*.aria2' -print0 2>/dev/null | while IFS= read -r -d '' file; do
        mv -f "${file}" "${base}/_torrent_files/" 2>/dev/null || true
      done
    fi
  done
fi

cat > "${MOUNT_FILE}" <<'EOF'
<?php
session_name('filemanager');
session_start();

if (empty($_SESSION['filemanager']['logged'])) {
    header('Location: /');
    exit;
}

function api_request(string $method, string $path, ?array $payload = null): array
{
    $url = 'https://127.0.0.1' . $path;
    $command = '/usr/bin/curl -sk --connect-timeout 10 --max-time 30 ';

    if ($method === 'POST') {
        $json = json_encode($payload ?? [], JSON_UNESCAPED_SLASHES);
        $command .= '-X POST -H ' . escapeshellarg('Content-Type: application/json') . ' ';
        $command .= '--data-binary ' . escapeshellarg($json) . ' ';
    }

    $command .= escapeshellarg($url);
    $response = @shell_exec($command);
    if (!is_string($response) || $response === '') {
        return ['code' => 1, 'msg' => 'API request failed'];
    }

    $decoded = json_decode($response, true);
    if (!is_array($decoded)) {
        return ['code' => 1, 'msg' => 'Invalid API response'];
    }

    return $decoded;
}

function wait_for_mount_state(string $file, bool $cdrom, bool $readOnly, int $attempts = 12, int $delayUs = 250000): bool
{
    for ($i = 0; $i < $attempts; $i++) {
        $state = api_request('GET', '/api/storage/image/mounted');
        $data = $state['data'] ?? [];
        if (
            ($data['file'] ?? '') === $file &&
            (bool)($data['cdrom'] ?? false) === $cdrom &&
            (bool)($data['readOnly'] ?? false) === $readOnly
        ) {
            return true;
        }
        usleep($delayUs);
    }
    return false;
}

function wait_for_unmount_state(int $attempts = 12, int $delayUs = 250000): bool
{
    for ($i = 0; $i < $attempts; $i++) {
        $state = api_request('GET', '/api/storage/image/mounted');
        $data = $state['data'] ?? [];
        if (($data['file'] ?? '') === '') {
            return true;
        }
        usleep($delayUs);
    }
    return false;
}

function stream_inline_file(string $rawFile): bool
{
    $relative = ltrim(str_replace('\\', '/', urldecode($rawFile)), '/');
    $relative = preg_replace('#/+#', '/', $relative);
    if (!is_string($relative) || $relative === '' || strpos($relative, '..') !== false) {
        return false;
    }

    $parts = explode('/', $relative, 2);
    $rootEntry = $parts[0] ?? '';
    if ($rootEntry === '') {
        return false;
    }

    $rootDir = __DIR__ . '/root';
    $realBase = realpath($rootDir . '/' . $rootEntry);
    $realFile = realpath($rootDir . '/' . $relative);
    if ($realBase === false || $realFile === false || !is_file($realFile) || !is_readable($realFile)) {
        return false;
    }

    $basePath = rtrim(str_replace('\\', '/', $realBase), '/');
    $filePath = str_replace('\\', '/', $realFile);
    if ($filePath !== $basePath && strpos($filePath, $basePath . '/') !== 0) {
        return false;
    }

    $size = filesize($realFile);
    if ($size === false || $size <= 0) {
        return false;
    }

    $mime = 'application/octet-stream';
    if (function_exists('mime_content_type')) {
        $detected = @mime_content_type($realFile);
        if (is_string($detected) && $detected !== '') {
            $mime = $detected;
        }
    }

    if (session_status() === PHP_SESSION_ACTIVE) {
        session_write_close();
    }

    header('Content-Description: File Transfer');
    header('Expires: 0');
    header('Cache-Control: private, max-age=0, must-revalidate');
    header('Pragma: public');
    header('Content-Transfer-Encoding: binary');
    header('Content-Type: ' . $mime);
    header('Content-Disposition: inline; filename="' . str_replace('"', '', basename($realFile)) . '"');
    header('Accept-Ranges: bytes');
    header('Content-Length: ' . $size);

    while (ob_get_level()) {
        ob_end_clean();
    }

    readfile($realFile);
    return true;
}

$notice = '';
$error = '';

$request = $_SERVER['REQUEST_METHOD'] === 'POST' ? $_POST : $_GET;

if (empty($request['action'])) {
    header('Location: /');
    exit;
}

if (!empty($request['action'])) {
    $action = $request['action'] ?? '';
    $file = $request['file'] ?? '';
    $readOnly = !empty($request['read_only']);
    $cdrom = ($request['cdrom'] ?? '1') === '1';
    $currentState = api_request('GET', '/api/storage/image/mounted');
    $currentData = $currentState['data'] ?? ['file' => '', 'cdrom' => false, 'readOnly' => false];

    if ($action === 'raw') {
        if (stream_inline_file($file)) {
            exit;
        }
        $result = ['code' => 1, 'msg' => 'File not found'];
    } elseif ($action === 'mount') {
        $payload = [
            'file' => $file,
            'cdrom' => $cdrom,
            'readOnly' => $readOnly,
        ];
        $needsReset =
            ($currentData['file'] ?? '') !== '' &&
            (
                ($currentData['file'] ?? '') !== $file ||
                (bool)($currentData['cdrom'] ?? false) !== $cdrom ||
                (bool)($currentData['readOnly'] ?? false) !== $readOnly
            );
        if ($needsReset) {
            $reset = api_request('POST', '/api/storage/image/mount', [
                'file' => '',
                'cdrom' => false,
                'readOnly' => false,
            ]);
            if (($reset['code'] ?? 1) === 0) {
                wait_for_unmount_state(16, 300000);
                usleep(500000);
            }
        }
        $result = api_request('POST', '/api/storage/image/mount', $payload);
        if (($result['code'] ?? 1) === 0 && !wait_for_mount_state($file, $cdrom, $readOnly)) {
            usleep(300000);
            $result = api_request('POST', '/api/storage/image/mount', $payload);
            if (($result['code'] ?? 1) === 0 && !wait_for_mount_state($file, $cdrom, $readOnly, 16, 300000)) {
                $result = ['code' => 1, 'msg' => 'Mount verification failed'];
            }
        }
    } elseif ($action === 'unmount') {
        $result = api_request('POST', '/api/storage/image/mount', [
            'file' => '',
            'cdrom' => false,
            'readOnly' => false,
        ]);
        if (($result['code'] ?? 1) === 0 && !wait_for_unmount_state()) {
            usleep(300000);
            $result = api_request('POST', '/api/storage/image/mount', [
                'file' => '',
                'cdrom' => false,
                'readOnly' => false,
            ]);
            if (($result['code'] ?? 1) === 0 && !wait_for_unmount_state(16, 300000)) {
                $result = ['code' => 1, 'msg' => 'Unmount verification failed'];
            }
        }
    } else {
        $result = ['code' => 1, 'msg' => 'Unknown action'];
    }

    if (($result['code'] ?? 1) === 0) {
        $notice = $action === 'unmount' ? 'Image unmounted.' : 'Image mounted.';
    } else {
        $error = $result['msg'] ?? 'Operation failed';
    }

    if (!empty($request['return'])) {
        $_SESSION['filemanager']['message'] = ($result['code'] ?? 1) === 0 ? $notice : $error;
        $_SESSION['filemanager']['status'] = ($result['code'] ?? 1) === 0 ? 'ok' : 'error';
        redirect_back($request['return']);
    }

    redirect_back('/');
}

$images = api_request('GET', '/api/storage/image');
$mounted = api_request('GET', '/api/storage/image/mounted');
$files = $images['data']['files'] ?? [];
$mountedData = $mounted['data'] ?? ['file' => '', 'cdrom' => false, 'readOnly' => false];

function h(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function redirect_back(?string $target): void
{
    if (!is_string($target) || $target === '') {
        return;
    }

    if (preg_match('#^(?:/|https?://)#i', $target) === 1) {
        header('Location: ' . $target);
        exit;
    }
}
?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>NanoKVM Pro Mount</title>
    <style>
        :root {
            color-scheme: dark;
            --bg: #11161c;
            --panel: #1a2129;
            --soft: #222c36;
            --line: #2c3947;
            --text: #eef3f8;
            --muted: #9fb0c2;
            --accent: #5ab1ff;
            --good: #2fc285;
            --warn: #ffcc59;
            --bad: #ff6f6f;
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            font-family: Arial, sans-serif;
            background: var(--bg);
            color: var(--text);
        }
        .wrap {
            max-width: 1120px;
            margin: 0 auto;
            padding: 24px;
        }
        .topbar, .card, .row {
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 16px;
        }
        .topbar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            padding: 18px 20px;
            margin-bottom: 18px;
        }
        .title {
            font-size: 34px;
            font-weight: 700;
            letter-spacing: 0.02em;
        }
        .actions {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
        }
        .btn, button {
            border: 0;
            border-radius: 12px;
            padding: 10px 14px;
            background: var(--soft);
            color: var(--text);
            cursor: pointer;
            font-size: 14px;
        }
        .btn {
            text-decoration: none;
            display: inline-flex;
            align-items: center;
        }
        .btn-primary { background: var(--accent); color: #07131f; font-weight: 700; }
        .btn-good { background: var(--good); color: #06150e; font-weight: 700; }
        .btn-warn { background: var(--warn); color: #201400; font-weight: 700; }
        .btn-bad { background: var(--bad); color: #230808; font-weight: 700; }
        .grid {
            display: grid;
            grid-template-columns: 1.1fr 1.9fr;
            gap: 18px;
        }
        .card {
            padding: 18px;
        }
        .label {
            color: var(--muted);
            font-size: 13px;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            margin-bottom: 8px;
        }
        .value {
            font-size: 18px;
            font-weight: 700;
            word-break: break-word;
        }
        .sub {
            color: var(--muted);
            font-size: 14px;
            margin-top: 8px;
        }
        .notice, .error {
            padding: 12px 14px;
            border-radius: 12px;
            margin-bottom: 16px;
            font-weight: 700;
        }
        .notice { background: rgba(47,194,133,0.18); color: #8ff0bf; }
        .error { background: rgba(255,111,111,0.18); color: #ffb3b3; }
        .list {
            display: grid;
            gap: 12px;
        }
        .row {
            padding: 14px;
        }
        .path {
            font-size: 16px;
            font-weight: 700;
            margin-bottom: 10px;
            word-break: break-all;
        }
        .controls {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
        }
        .checkbox {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            color: var(--muted);
            padding: 0 4px;
        }
        .current {
            border-color: var(--accent);
            box-shadow: 0 0 0 1px rgba(90,177,255,0.3) inset;
        }
        @media (max-width: 900px) {
            .grid { grid-template-columns: 1fr; }
            .title { font-size: 28px; }
        }
    </style>
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%23070707'/%3E%3Crect x='4' y='4' width='56' height='56' rx='12' fill='none' stroke='%23c51616' stroke-width='4'/%3E%3Cpath d='M18 18h8v10h12V18h8v28h-8V36H26v10h-8z' fill='%23ffffff'/%3E%3C/svg%3E">
</head>
<body>
    <div class="wrap">
        <div class="topbar">
            <div class="title">NanoKVM Pro</div>
            <div class="actions">
                <a class="btn" href="/">Files</a>
                <form method="post" style="margin:0">
                    <input type="hidden" name="action" value="unmount">
                    <button type="submit" class="btn btn-bad">Unmount</button>
                </form>
            </div>
        </div>

        <?php if ($notice !== ''): ?>
            <div class="notice"><?php echo h($notice); ?></div>
        <?php endif; ?>
        <?php if ($error !== ''): ?>
            <div class="error"><?php echo h($error); ?></div>
        <?php endif; ?>

        <div class="grid">
            <div class="card">
                <div class="label">Mounted Image</div>
                <div class="value"><?php echo h($mountedData['file'] !== '' ? $mountedData['file'] : 'Not mounted'); ?></div>
                <div class="sub">
                    Mode: <?php echo !empty($mountedData['cdrom']) ? 'CD-ROM' : 'Mass Storage'; ?><br>
                    Read only: <?php echo !empty($mountedData['readOnly']) ? 'Yes' : 'No'; ?>
                </div>
            </div>

            <div class="card">
                <div class="label">Available Images</div>
                <div class="list">
                    <?php foreach ($files as $file): ?>
                        <?php
                            $isCurrent = $file === ($mountedData['file'] ?? '');
                            $isImage = preg_match('/\.(iso|img|bin|raw|dd|ima|dsk|vfd|efi|vhd|vhdx|cue|mdf|mds|vmdk|qcow2|dmg)$/i', $file) === 1;
                        ?>
                        <div class="row<?php echo $isCurrent ? ' current' : ''; ?>">
                            <div class="path"><?php echo h($file); ?></div>
                            <div class="controls">
                                <?php if ($isImage): ?>
                                    <form method="post" style="margin:0">
                                        <input type="hidden" name="action" value="mount">
                                        <input type="hidden" name="file" value="<?php echo h($file); ?>">
                                        <input type="hidden" name="cdrom" value="1">
                                        <label class="checkbox">
                                            <input type="checkbox" name="read_only" value="1" checked>
                                            Read only
                                        </label>
                                        <button type="submit" class="btn btn-primary">Mount CD-ROM</button>
                                    </form>
                                    <form method="post" style="margin:0">
                                        <input type="hidden" name="action" value="mount">
                                        <input type="hidden" name="file" value="<?php echo h($file); ?>">
                                        <input type="hidden" name="cdrom" value="0">
                                        <label class="checkbox">
                                            <input type="checkbox" name="read_only" value="1">
                                            Read only
                                        </label>
                                        <button type="submit" class="btn btn-good">Mount Mass Storage</button>
                                    </form>
                                <?php else: ?>
                                    <div class="sub">Mounting is enabled for .iso, .img, .bin, .raw, .dd, .ima, .dsk, .vfd, .efi, .vhd, .vhdx, .cue, .mdf, .mds, .vmdk, .qcow2, .dmg</div>
                                <?php endif; ?>
                            </div>
                        </div>
                    <?php endforeach; ?>
                </div>
            </div>
        </div>
    </div>
</body>
</html>
EOF

PASSWORD_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "${PASSWORD}")"

TFM_USERNAME="${USERNAME}" TFM_PASSWORD_HASH="${PASSWORD_HASH}" TFM_CONFIG_FILE="${CONFIG_FILE}" python3 - <<'PY'
import os
from pathlib import Path

username = os.environ["TFM_USERNAME"]
password_hash = os.environ["TFM_PASSWORD_HASH"]
config_path = Path(os.environ["TFM_CONFIG_FILE"])
config_json = '{"lang":"en","error_reporting":false,"show_hidden":true,"hide_Cols":true,"theme":"dark"}'
config = (
    "<?php\n"
    "//Default Configuration\n"
    "$CONFIG = " + repr(config_json) + ";\n\n"
    "$use_auth = true;\n"
    "$auth_users = array(\n"
    f"    {username!r} => {password_hash!r},\n"
    ");\n"
    "$readonly_users = array();\n"
    "$global_readonly = false;\n"
    "$default_timezone = 'Asia/Seoul';\n"
    "$root_path = __DIR__ . '/root';\n"
    "$root_url = 'root';\n"
    "$path_display_mode = 'relative';\n"
    "$online_viewer = false;\n"
    "$exclude_items = array();\n"
    "$max_upload_size_bytes = 1000000000000;\n"
    "$upload_chunk_size_bytes = 4000000;\n"
)

config_path.write_text(config, encoding="utf-8")
PY

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Tiny File Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/php -d upload_max_filesize=1000G -d post_max_size=1000G -d max_execution_time=0 -d max_input_time=-1 -d memory_limit=-1 -d upload_tmp_dir=/tmp -S 0.0.0.0:${PORT} -t ${INSTALL_DIR}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > "${ARIA2_SERVICE_FILE}" <<EOF
[Unit]
Description=Tiny File Manager aria2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/aria2c --conf-path=${ARIA2_CONFIG_FILE}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" >/dev/null
systemctl enable "${ARIA2_SERVICE_NAME}.service" >/dev/null
systemctl restart "${ARIA2_SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"
php -l "${APP_FILE}" >/dev/null
php -l "${CONFIG_FILE}" >/dev/null
php -l "${MOUNT_FILE}" >/dev/null

echo
echo "Tiny File Manager installed."
echo "URL: http://$(hostname -I | awk '{print $1}'):${PORT}/"
echo "Login: ${USERNAME}"
echo "Password: ${PASSWORD}"
echo "Root folders: /data and /sdcard"
