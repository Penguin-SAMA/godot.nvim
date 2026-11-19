@tool
extends EditorPlugin

const Scenes = preload("scene_actions.gd")
const RECORD := "res://.godot/godot-nvim-editor.json"
const MAX_REQUEST := 1024 * 1024

var server := TCPServer.new()
var peers := {}
var token := ""
var key_path := ""
var busy := false
var scenes: RefCounted
var startup_args := PackedStringArray()
var published := ""


# Godot consumes its --lsp-port and --dap-port flags before GDScript starts.
# Read this process's launch arguments once when an independent editor starts.
func _startup_args() -> PackedStringArray:
	if OS.has_environment("NVIM_BRIDGE_PORT") and OS.has_environment("GODOT_NVIM_LSP_PORT"):
		return ["--lsp-port", OS.get_environment("GODOT_NVIM_LSP_PORT"), "--dap-port", OS.get_environment("GODOT_NVIM_DAP_PORT")]
	var output := []
	var pid := str(OS.get_process_id())
	if OS.get_name() == "Windows":
		var query := "(Get-CimInstance Win32_Process -Filter ('ProcessId=' + %s)).CommandLine" % pid
		OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", query], output)
	else:
		OS.execute("ps", ["-ww", "-p", pid, "-o", "command="], output)
	if output.is_empty():
		return OS.get_cmdline_args()
	var flags := RegEx.new()
	flags.compile("(?:^|\\s)(--lsp-port|--dap-port)\\s+\"?(\\d+)\"?(?=\\s|$)")
	var args := PackedStringArray()
	for hit in flags.search_all(str(output[0])):
		args.append(hit.get_string(1))
		args.append(hit.get_string(2))
	return args


func _setting_port(flag: String, setting: String, fallback: int) -> int:
	var args := startup_args
	var at := args.find(flag)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1].to_int()
	var settings := EditorInterface.get_editor_settings()
	return int(settings.get_setting(setting)) if settings.has_setting(setting) else fallback


func _identity() -> Dictionary:
	return {
		"version": Engine.get_version_info()["string"],
		"root": ProjectSettings.globalize_path("res://"),
		"pid": OS.get_process_id(),
		"mode": "headless" if DisplayServer.get_name() == "headless" else "editor",
		"bridge_port": server.get_local_port(),
		"lsp_port": _setting_port("--lsp-port", "network/language_server/remote_port", 6005),
		"dap_port": _setting_port("--dap-port", "network/debug_adapter/remote_port", 6006),
	}


func _publish(path: String, content: String) -> bool:
	var temp := path + ".%d.tmp" % OS.get_process_id()
	var f := FileAccess.open(temp, FileAccess.WRITE)
	if f == null:
		return false
	FileAccess.set_unix_permissions(temp, 384) # 0600 on Unix.
	f.store_string(content)
	f.close()
	return DirAccess.rename_absolute(temp, path) == OK


func _enter_tree() -> void:
	scenes = Scenes.new(self)
	startup_args = _startup_args()
	var port := OS.get_environment("NVIM_BRIDGE_PORT").to_int()
	if server.listen(port, "127.0.0.1") != OK:
		push_error("Neovim bridge could not listen on port %s" % port)
		return
	token = Crypto.new().generate_random_bytes(32).hex_encode()
	key_path = "res://.godot/godot-nvim-bridge-%d.key" % OS.get_process_id()
	if not _publish(key_path, token):
		server.stop()
		push_error("Neovim bridge could not write its project connection file")
		return
	if DisplayServer.get_name() != "headless":
		_update_record()
		EditorInterface.get_editor_settings().settings_changed.connect(_update_record)


func _update_record() -> void:
	var record := JSON.stringify(_identity())
	if published != record and _publish(RECORD, record):
		published = record


func _exit_tree() -> void:
	for peer in peers.keys():
		peer.disconnect_from_host()
	peers.clear()
	server.stop()
	if key_path != "":
		DirAccess.remove_absolute(key_path)
	if FileAccess.file_exists(RECORD):
		var record: Variant = JSON.parse_string(FileAccess.get_file_as_string(RECORD))
		if record is Dictionary and int(record.get("pid", 0)) == OS.get_process_id():
			DirAccess.remove_absolute(RECORD)


func _handles(object: Object) -> bool:
	return object is Shader or object is ShaderInclude


func _edit(object: Object) -> void:
	if not _handles(object) or not Scenes.valid_resource(object.resource_path):
		return
	for peer in peers.keys():
		if peers[peer].authenticated:
			_send(peer, {"event": "open_file", "data": {"path": object.resource_path}})


func _send(peer: StreamPeerTCP, value: Dictionary) -> void:
	if peers.has(peer):
		peer.put_data((JSON.stringify(value) + "\n").to_utf8_buffer())


func _process(_delta: float) -> void:
	if not server.is_listening():
		return
	while server.is_connection_available():
		var peer := server.take_connection()
		if peers.size() >= 32:
			peer.disconnect_from_host()
		else:
			peers[peer] = {"bytes": PackedByteArray(), "authenticated": false, "since": Time.get_ticks_msec()}
	for peer: StreamPeerTCP in peers.keys():
		peer.poll()
		var state: Dictionary = peers[peer]
		if not state.authenticated and Time.get_ticks_msec() - state.since > 5000:
			peer.disconnect_from_host()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			peers.erase(peer)
			continue
		var count := peer.get_available_bytes()
		if count <= 0:
			continue
		if count + state.bytes.size() > MAX_REQUEST:
			peer.disconnect_from_host()
			continue
		var chunk := peer.get_data(count)
		if chunk[0] != OK:
			peer.disconnect_from_host()
			continue
		var bytes: PackedByteArray = state.bytes
		bytes.append_array(chunk[1])
		var end := bytes.find(10)
		while end >= 0:
			var request: Variant = JSON.parse_string(bytes.slice(0, end).get_string_from_utf8())
			bytes = bytes.slice(end + 1)
			if not request is Dictionary or not request.get("params", {}) is Dictionary:
				peer.disconnect_from_host()
				break
			_dispatch(peer, request)
			end = bytes.find(10)
		state.bytes = bytes


func _dispatch(peer: StreamPeerTCP, request: Dictionary) -> void:
	var id: Variant = request.get("id")
	var method: String = str(request.get("method", ""))
	var params: Dictionary = request.get("params", {})
	var result: Variant
	if method == "hello" and params.get("token", "") == token and token != "":
		peers[peer].authenticated = true
		result = _identity()
	elif not peers[peer].authenticated:
		peer.disconnect_from_host()
		return
	elif method == "ping":
		result = _identity()
	elif method == "resolve":
		var path: String = str(params.get("path", ""))
		if path.begins_with("uid://"):
			var uid := ResourceUID.text_to_id(path)
			path = ResourceUID.get_id_path(uid) if ResourceUID.has_id(uid) else ""
		if Scenes.valid_resource(path) and FileAccess.file_exists(path):
			result = {"path": path}
		else:
			result = {"error": "Cannot locate resource: " + str(params.get("path", ""))}
	elif DisplayServer.get_name() == "headless":
		result = {"error": "Open the graphical Godot editor for scene or editor commands."}
	elif method == "configure_external":
		if params.get("executable", "") == "" or not params.get("flags") is String:
			result = {"error": "Missing external editor executable or flags"}
		else:
			var settings := EditorInterface.get_editor_settings()
			settings.set_setting("text_editor/external/exec_path", params.executable)
			settings.set_setting("text_editor/external/exec_flags", params.flags)
			settings.set_setting("text_editor/external/use_external_editor", true)
			result = {"ok": true}
	elif method == "edit_resource" or method == "edit_script":
		var path := str(params.get("path", params.get("script", "")))
		if not Scenes.valid_resource(path) or not ResourceLoader.exists(path):
			result = {"error": "Unknown resource: " + path}
		else:
			var asset := ResourceLoader.load(path)
			if method == "edit_script" and asset is Script:
				EditorInterface.edit_script(asset, int(params.get("line", 1)), int(params.get("column", 1)))
			else:
				EditorInterface.edit_resource(asset)
			result = {"ok": true}
	elif busy:
		result = {"error": "Another editor action is in progress. Retry after it finishes."}
	else:
		busy = true
		result = await scenes.dispatch(method, params)
		busy = false
	if result is Dictionary and result.has("error"):
		_send(peer, {"id": id, "error": result.error})
	else:
		_send(peer, {"id": id, "result": result})
