extends Node
## Dev-only: confirm the renamed towers/paths reach the runtime, and that no
## description still names a path that does not exist.
func drive(main) -> void:
	print("NAMES: %-10s %-10s %s" % ["id", "name", "paths"])
	for id in main.content.tower_ids():
		var td = main.content.tower(id)
		var paths := []
		for u in td.upgrades:
			paths.append(str(u.get("name", "?")))
		print("NAMES: %-10s %-10s %s" % [id, td.display_name, ", ".join(paths)])
	print("NAMES: --- ghost references in descriptions ---")
	var known := ["ECC", "Encrypted", "TLS", "Cipher", "Bit Corruption", "Buffer Overflow",
		"Tunneling", "Denial of Service", "Garbage Collection", "Prefocus", "Execute"]
	var re := RegEx.new()
	re.compile("\\b[A-Z][a-zA-Z]+(?: [A-Z][a-zA-Z]+)*\\b")
	for id in main.content.tower_ids():
		var td = main.content.tower(id)
		var paths := []
		for u in td.upgrades:
			paths.append(str(u.get("name", "?")))
		var ghosts := []
		for m in re.search_all(td.description):
			var w: String = m.get_string()
			if w in known or w in paths or w == td.display_name:
				continue
			if td.description.begins_with(w) or ("\n" + w) in td.description:
				continue          # sentence-initial word, not a name
			ghosts.append(w)
		if not ghosts.is_empty():
			print("NAMES:   %-10s %s" % [td.display_name, str(ghosts)])
	print("NAMES: done")
