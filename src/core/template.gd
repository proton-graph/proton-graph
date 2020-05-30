tool
class_name ConceptGraphTemplate
extends GraphEdit

"""
Template are the node graph edited from the inspector
"""


signal graph_changed
signal connection_changed
signal output_ready
signal simulation_started
signal simulation_outdated
signal simulation_completed
signal thread_completed


var concept_graph
var root: Spatial
var node_library: ConceptNodeLibrary	# Injected from the concept graph
var undo_redo: UndoRedo
var paused := false
var restart_generation := false

var _timer := Timer.new()
var _simulation_delay := 0.075
var _json_util = load(ConceptGraphEditorUtil.get_plugin_root_path() + "/src/thirdparty/json_beautifier/json_beautifier.gd")
var _output_nodes := [] # of ConceptNodes
var _template_loaded := false
var _node_pool := ConceptGraphNodePool.new()
var _thread_pool := ConceptGraphThreadPool.new()
var _registered_resources := []
var _copy_buffer = []
var _connections_buffer = []
var _clear_cache_on_next_run := false
var _thread: Thread
var _is_thread_busy := false
var _output := []


func _init() -> void:
	_setup_gui()
	ConceptGraphDataType.setup_valid_connection_types(self)
	connect("output_ready", self, "_on_output_ready")
	connect("connection_request", self, "_on_connection_request")
	connect("disconnection_request", self, "_on_disconnection_request")
	connect("copy_nodes_request", self, "_on_copy_nodes_request")
	connect("paste_nodes_request", self, "_on_paste_nodes_request")
	connect("delete_nodes_request", self, "_on_delete_nodes_request")
	connect("duplicate_nodes_request", self, "_on_duplicate_nodes_request")
	connect("_end_node_move", self, "_on_node_changed_zero")
	connect("thread_completed", self, "_on_thread_completed")

	_timer.one_shot = true
	_timer.autostart = false
	_timer.connect("timeout", self, "_run_simulation")
	add_child(_timer)


"""
Remove all children and connections
"""
func clear() -> void:
	_template_loaded = false
	clear_editor()
	_output_nodes = []
	run_garbage_collection()


func clear_editor() -> void:
	clear_connections()
	for c in get_children():
		if c is GraphNode:
			remove_child(c)
			c.free()


"""
Creates a node using the provided model and add it as child which makes it visible and editable
from the Concept Graph Editor
"""
func create_node(node: ConceptNode, data := {}, notify := true) -> ConceptNode:
	var new_node: ConceptNode = node.duplicate()
	new_node.offset = scroll_offset + Vector2(250, 150)
	new_node.thread_pool = _thread_pool

	if new_node.unique_id.find("_output") != -1:
		_output_nodes.append(new_node)
		new_node.connect("output_ready", self, "_on_output_ready")

	add_child(new_node)
	_connect_node_signals(new_node)

	if data.has("name"):
		new_node.name = data["name"]
	if data.has("editor"):
		new_node.restore_editor_data(data["editor"])
	if data.has("data"):
		new_node.restore_custom_data(data["data"])

	if notify:
		emit_signal("graph_changed")
		emit_signal("simulation_outdated")

	return new_node


func delete_node(node) -> void:
	if node.unique_id.find("_output") != -1:
		_output_nodes.erase(node)

	_disconnect_node_signals(node)
	_disconnect_active_connections(node)
	remove_child(node)
	emit_signal("graph_changed")
	emit_signal("simulation_outdated")
	update() # Force the GraphEdit to redraw to hide the old connections to the deleted node


func restore_node(node) -> void:
	if node.unique_id.find("_output") != -1:
		_output_nodes.append(node)

	_connect_node_signals(node)
	add_child(node)
	emit_signal("graph_changed")
	emit_signal("simulation_outdated")


"""
Add custom properties in the ConceptGraph inspector panel to expose variables at the instance level.
This is used to change parameters on an instance without having to modify the template itself
(And thus modifying all the other ConceptGraph using the same template).
"""
func update_exposed_variables() -> void:
	var exposed_variables = []
	for c in get_children():
		if c is ConceptNode:
			var variables = c.get_exposed_variables()
			if not variables:
				continue
			for v in variables:
				v.name = "Template/" + v.name
				v.type = ConceptGraphDataType.to_variant_type(v.type)
				exposed_variables.append(v)

	concept_graph.update_exposed_variables(exposed_variables)


"""
Get exposed variable from the inspector
"""
func get_value_from_inspector(name: String):
	return concept_graph.get("Template/" + name)


"""
Clears the cache of every single node in the template. Useful when only the inputs changes
and node the whole graph structure itself. Next time get_output is called, every nodes will
recalculate their output
"""
func clear_simulation_cache() -> void:
	for node in get_children():
		if node is ConceptNode:
			node.clear_cache()
	run_garbage_collection()
	_clear_cache_on_next_run = false


"""
This is the exposed API to run the simulation but doesn't run it immediately in case it get called
multiple times in a very short interval (Moving or resizing an input can cause this).
Actual simulation happens in _run_simulation
"""
func generate(force_full_simulation := false) -> void:
	if paused:
		return
	_timer.start(_simulation_delay)
	_clear_cache_on_next_run = _clear_cache_on_next_run or force_full_simulation
	emit_signal("simulation_started")


"""
Returns the final result generated by the whole graph
"""
func get_output() -> Array:
	return _output


"""
Returns an array of ConceptNodes connected to the left of the given slot, including the slot index
the connection originates from
"""
func get_left_nodes(node: ConceptNode, slot: int) -> Array:
	var result = []
	for c in get_connection_list():
		if c["to"] == node.get_name() and c["to_port"] == slot:
			var data = {
				"node": get_node(c["from"]),
				"slot": c["from_port"]
			}
			result.append(data)
	return result


"""
Returns an array of ConceptNodes connected to the right of the given slot.
"""
func get_right_nodes(node: ConceptNode, slot: int) -> Array:
	var result = []
	for c in get_connection_list():
		if c["from"] == node.get_name() and c["from_port"] == slot:
			result.append(get_node(c["to"]))
	return result


"""
Returns an array of all the ConceptNodes on the left, regardless of the slot.
"""
func get_all_left_nodes(node) -> Array:
	var result = []
	for c in get_connection_list():
		if c["to"] == node.get_name():
			result.append(get_node(c["from"]))
	return result


"""
Returns an array of all the ConceptNodes on the right, regardless of the slot.
"""
func get_all_right_nodes(node) -> Array:
	var result = []
	for c in get_connection_list():
		if c["from"] == node.get_name():
			result.append(get_node(c["to"]))
	return result


"""
Returns true if the given node is connected to the given slot
"""
func is_node_connected_to_input(node: GraphNode, idx: int) -> bool:
	var name = node.get_name()
	for c in get_connection_list():
		if c["to"] == name and c["to_port"] == idx:
			return true
	return false


"""
Opens a cgraph file, reads its contents and recreate a node graph from there
"""
func load_from_file(path: String, soft_load := false) -> void:
	if not node_library or not path or path == "":
		return

	_template_loaded = false
	if soft_load:	# Don't clear, simply refresh the graph edit UI without running the sim
		clear_editor()
	else:
		clear()

	# Open the file and read the contents
	var file = File.new()
	file.open(path, File.READ)
	var json = JSON.parse(file.get_as_text())
	if not json or not json.result:
		print("Failed to parse json")
		return	# Template file is either empty or not a valid Json. Ignore

	# Abort if the file doesn't have node data
	var graph: Dictionary = json.result
	if not graph.has("nodes"):
		return

	# For each node found in the template file
	var node_list = node_library.get_list()
	for node_data in graph["nodes"]:
		if not node_data.has("type"):
			continue

		var type = node_data["type"]
		if not node_list.has(type):
			print("Error: Node type ", type, " could not be found.")
			continue

		# Get a graph node from the node_library and use it as a model to create a new one
		var node_instance = node_list[type]
		create_node(node_instance, node_data, false)

	for c in graph["connections"]:
		# TODO: convert the to/from ports stored in file to actual port
		connect_node(c["from"], c["from_port"], c["to"], c["to_port"])
		get_node(c["to"]).emit_signal("connection_changed")

	_template_loaded = true


func save_to_file(path: String) -> void:
	var graph := {}
	# TODO : Convert the connection_list to an ID connection list
	graph["connections"] = get_connection_list()
	graph["nodes"] = []

	for c in get_children():
		if c is ConceptNode:
			var node = {}
			node["name"] = c.get_name()
			node["type"] = c.unique_id
			node["editor"] = c.export_editor_data()
			node["data"] = c.export_custom_data()
			graph["nodes"].append(node)

	var json = _json_util.beautify_json(to_json(graph))
	var file = File.new()
	file.open(path, File.WRITE)
	file.store_string(json)
	file.close()


"""
Manual garbage collection handling. Before each generation, we clean everything the graphnodes may
have created in the process. Because graphnodes hand over their result to the next one, they can't
handle the removal themselves as they don't know if the resource is still in use or not.
"""
func register_to_garbage_collection(resource):
	if resource is Object:
		_registered_resources.append(weakref(resource))


"""
Iterate over all the registered resources and free them if they still exist
"""
func run_garbage_collection():
	for res in _registered_resources:
		var resource = res.get_ref()
		if resource:
			if resource is Node:
				var parent = resource.get_parent()
				if parent:
					parent.remove_child(resource)
				resource.queue_free()
			elif resource is Object:
				resource.free()
	_registered_resources = []


"""
Simulation is a background process, this ask all the output nodes to get their output ready. Each
of them will emit a output_ready signal when they are done.
"""
func _run_simulation() -> void:
	if not _thread:
		_thread = Thread.new()

	if _thread.is_active():
		# Let the thread finish (as there's no way to cancel it) and start the generation again
		restart_generation = true
		return

	restart_generation = false

	if _clear_cache_on_next_run:
		clear_simulation_cache()

	_thread.start(self, "_run_simulation_threaded")


func _run_simulation_threaded(_var = null) -> void:
	if _output_nodes.size() == 0:
		if _template_loaded:
			print("Error : No output node found in ", get_parent().get_name())
			call_deferred("emit_signal", "thread_completed")

	var node_output
	for node in _output_nodes:
		if not node:
			_output_nodes.erase(node)
			continue

		node_output = node.get_output(0)
		if node_output == null:
			continue
		if not node_output is Array:
			node_output = [node_output]

		_output += node_output

	call_deferred("emit_signal", "thread_completed")


func _setup_gui() -> void:
	right_disconnects = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	anchor_right = 1.0
	anchor_bottom = 1.0


func _connect_node_signals(node) -> void:
	node.connect("node_changed", self, "_on_node_changed")
	node.connect("close_request", self, "_on_delete_nodes_request", [node])
	node.connect("dragged", self, "_on_node_dragged", [node])


func _disconnect_node_signals(node) -> void:
	node.disconnect("node_changed", self, "_on_node_changed")
	node.disconnect("close_request", self, "_on_delete_nodes_request")
	node.disconnect("dragged", self, "_on_node_dragged")


func _disconnect_active_connections(node: GraphNode) -> void:
	var name = node.get_name()
	for c in get_connection_list():
		if c["to"] == name or c["from"] == name:
			disconnect_node(c["from"], c["from_port"], c["to"], c["to_port"])


func _disconnect_input(node: GraphNode, idx: int) -> void:
	var name = node.get_name()
	for c in get_connection_list():
		if c["to"] == name and c["to_port"] == idx:
			disconnect_node(c["from"], c["from_port"], c["to"], c["to_port"])
			return


func _get_selected_nodes() -> Array:
	var nodes = []
	for c in get_children():
		if c is GraphNode and c.selected:
			nodes.append(c)
	return nodes


func _duplicate_node(node: ConceptNode) -> ConceptNode:
	var res: ConceptNode = node.duplicate(7)
	res.init_from_node(node)
	res._initialized = true
	return res


func _on_thread_completed() -> void:
	_thread.wait_to_finish()
	if restart_generation:
		generate()
	else:
		emit_signal("simulation_completed")


func _on_connection_request(from_node: String, from_slot: int, to_node: String, to_slot: int) -> void:
	# Prevent connecting the node to itself
	if from_node == to_node:
		return

	# Disconnect any existing connection to the input slot first unless multi connection is enabled
	var node = get_node(to_node)
	if not node.is_multiple_connections_enabled_on_slot(to_slot):
		for c in get_connection_list():
			if c["to"] == to_node and c["to_port"] == to_slot:
				disconnect_node(c["from"], c["from_port"], c["to"], c["to_port"])
				break

	connect_node(from_node, from_slot, to_node, to_slot)
	emit_signal("graph_changed")
	emit_signal("simulation_outdated")
	get_node(to_node).emit_signal("connection_changed")


func _on_disconnection_request(from_node: String, from_slot: int, to_node: String, to_slot: int) -> void:
	disconnect_node(from_node, from_slot, to_node, to_slot)
	emit_signal("graph_changed")
	emit_signal("simulation_outdated")
	get_node(to_node).emit_signal("connection_changed")


# Preserving 3.1 compatibility. Otherwise, just add a default "= null" to the node parameter
func _on_node_changed_zero():
	_on_node_changed(null, false)


func _on_node_changed(node: ConceptNode, replay_simulation := false) -> void:
	# Prevent regeneration hell while loading the template from file
	if not _template_loaded:
		return

	emit_signal("graph_changed")
	if replay_simulation:
		emit_signal("simulation_outdated")


func _on_node_dragged(from: Vector2, to: Vector2, node: ConceptNode) -> void:
	undo_redo.create_action("Move " + node.display_name)
	undo_redo.add_do_method(node, "set_offset", to)
	undo_redo.add_undo_method(node, "set_offset", from)
	undo_redo.commit_action()


func _on_copy_nodes_request() -> void:
	_copy_buffer = []
	_connections_buffer = get_connection_list()

	for node in _get_selected_nodes():
		var new_node = _duplicate_node(node)
		new_node.name = node.name	# Needed to retrieve active connections later
		new_node.offset -= scroll_offset
		_copy_buffer.append(new_node)
		node.selected = false


func _on_paste_nodes_request() -> void:
	if _copy_buffer.empty():
		return

	var tmp = []

	undo_redo.create_action("Copy " + String(_copy_buffer.size()) + " GraphNode(s)")
	for node in _copy_buffer:
		var new_node = _duplicate_node(node)
		tmp.append(new_node)
		new_node.selected = true
		new_node.offset += scroll_offset + Vector2(80, 80)
		undo_redo.add_do_method(self, "restore_node", new_node)
		undo_redo.add_do_method(new_node, "regenerate_default_ui")
		undo_redo.add_undo_method(self, "remove_child", new_node)
	undo_redo.commit_action()

	# I couldn't find a way to merge these in a single action because the connect_node can't be called
	# if the child was not added to the tree first.
	undo_redo.create_action("Create connections")
	for co in _connections_buffer:
		var from := -1
		var to := -1

		for i in _copy_buffer.size():
			var name = _copy_buffer[i].get_name()
			if name == co["from"]:
				from = i
			elif name == co["to"]:
				to = i

		if from != -1 and to != -1:
			undo_redo.add_do_method(self, "connect_node", tmp[from].get_name(), co["from_port"], tmp[to].get_name(), co["to_port"])
			undo_redo.add_undo_method(self, "disconnect_node", tmp[from].get_name(), co["from_port"], tmp[to].get_name(), co["to_port"])

	undo_redo.commit_action()


func _on_delete_nodes_request(selected = null) -> void:
	if not selected:
		selected = _get_selected_nodes()
	elif not selected is Array:
		selected = [selected]
	if selected.size() == 0:
		return

	undo_redo.create_action("Delete " + String(selected.size()) + " GraphNode(s)")
	for node in selected:
		undo_redo.add_do_method(self, "delete_node", node)
		undo_redo.add_undo_method(self, "restore_node", node)

	undo_redo.commit_action()
	update()


func _on_duplicate_nodes_request() -> void:
	_on_copy_nodes_request()
	_on_paste_nodes_request()
