extends SceneTree


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 1 and args[0].begins_with("uid://"):
		var id := ResourceUID.text_to_id(args[0])
		if ResourceUID.has_id(id):
			var path := ResourceUID.get_id_path(id)
			if path.begins_with("res://") and FileAccess.file_exists(path):
				print("GODOT_NVIM_RESOURCE=" + path)
				quit(0)
				return
	quit(1)
