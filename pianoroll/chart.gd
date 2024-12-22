extends Control

signal chart_updated

const scrollbar_height : float = 8

var scroll_position : float:
	get: return %ChartView.scroll_horizontal
	set(with): %ChartView.scroll_horizontal = with
var scroll_end : float:
	get: return scroll_position + %ChartView.size.x
var scroll_center : float:
	get: return (scroll_position + scroll_end) / 2.0
	set(with):
		var halfscreen = (scroll_end - scroll_position) / 2.0
		scroll_position = with - halfscreen
var view_bounds: ViewBounds:
	get: return ViewBounds.new(x_to_bar(scroll_position),x_to_bar(scroll_end))
	set(_with): pass # would a function to set the scroll and zoom together be useful?
class ViewBounds:	# effectively a vector2 with nicer code completion
					# these values are in bars, not pixels
	var left: float
	var right:float
	var center: float:
		get: return (left + right) / 2.0
		set(_v): assert(false)
	func _init(left_bound, right_bound):
		self.left = left_bound
		self.right = right_bound

var bar_spacing : float = 1.0
var middle_c_y : float:
	get: return (key_height * 13.0) + (key_height / 2.0)
var key_height : float:
	get: return (size.y + scrollbar_height) / Global.NUM_KEYS
var current_subdiv : float:
	get: return 1.0 / %TimingSnap.value
var note_scn = preload("res://note/note.tscn")
var settings : Settings:
	get: return Global.settings
var bar_font : Font
var draw_targets : bool:
	get: return %ShowMouseTargets.button_pressed
var doot_enabled : bool = true
var _update_queued := false
var clearing_notes := false
var prev_section_start : float = 0.0
func height_to_pitch(height:float):
	return ((height - middle_c_y) / key_height) * Global.SEMITONE
func pitch_to_height(pitch:float):
	return middle_c_y - ((pitch / Global.SEMITONE) * key_height)
func x_to_bar(x:float): return x / bar_spacing
func bar_to_x(bar:float): return bar * bar_spacing
@onready var main = get_tree().get_current_scene()
@onready var player : AudioStreamPlayer = %TrombPlayer
@onready var measure_font : Font = ThemeDB.get_fallback_font()
@onready var tmb : TMBInfo:
	get: return Global.working_tmb

enum {
	EDIT_MODE,
	SELECT_MODE,
}
var mouse_mode : int = EDIT_MODE
var show_preview : bool = false
var playhead_preview : float = 0.0
### Dew variables ###
var rev : int   # the "act" setter determines which revision is to be activated by adding 1 if redoing.
				# Redoing enacts next edit in line(+1) (NOT FOR DRAGS OR PASTE), and undoing enacts current edit(+0).
				# Drag edits are stored as an array containing 1-3 arrays, each subarray containing [a note's reference, its old data, its new data].
enum { UR_NONE = -1, UR_UNDO =  0, UR_REDO =  1, }
var ur_type : int = UR_NONE:
	set(value):
		rev = Global.revision + value 
		ur_type = value
var action := Global.ACTION_NONE # initial value, set equal to Global.actions[Global.revision] on successful undo/redo input
var stuffed_note : Note # note reference waiting to be altered (stuffed with desired data) when u/r-ing a drag
enum { # enumerates the three indices of a DRAGGED note set: [note_reference, pre-drag_data, post-drag_data]
	REF,
	OLD,
	NEW
}
### Dew variables ###

var should_doot: bool:
	get: return doot_enabled && !Global.in_ur && !Global.pasting && !%PreviewController.is_playing
func doot(pitch:float):
	if !should_doot: return
	player.pitch_scale = Global.pitch_to_scale(pitch / Global.SEMITONE)
	player.play()
	await(get_tree().create_timer(0.1).timeout)
	player.stop()


func _ready() -> void:
	bar_font = measure_font.duplicate()
	main.chart_loaded.connect(_on_tmb_loaded)
	Global.tmb_updated.connect(_on_tmb_updated)
	%TimingSnap.value_changed.connect(timing_snap_changed)


func _process(_delta) -> void:
	if _update_queued: _do_tmb_update()
	if %PreviewController.is_playing: queue_redraw()


func _on_scroll_change() -> void:
	await(get_tree().process_frame)
	queue_redraw()
	redraw_notes()
	%WavePreview.calculate_width()

## Dew u/r shortcut inputs
func _shortcut_input(_event) -> void:
	if Input.is_action_just_pressed("ui_undo",true):
		print("\n",Global.revision,": undo pressed...","\n")
		if Global.revision != -1: # if we're at the beginning of edit history, there are no changes to undo!
			ur_type = UR_UNDO
			if Global.actions[rev] < 2:		  # If we aren't undoing a drag or copy-paste, we can just swap the original action taken.
				action = !Global.actions[rev] # Undoing an added note(0) deletes it(1); undoing a deleted note(1) adds it back(0).
			else:							  # Negating these manual actions keeps logic progressing forward through edit chain.
				action = Global.actions[rev]  # Drag and copy-paste store both their prior and former states side-by-side, so we deal with the swap later.
			Global.revision -= 1
			ur_handler()
	if Input.is_action_just_pressed("ui_redo"):
		print("\n",Global.revision,": redo pressed...","\n")
		if Global.revision < Global.actions.size()-1: # revision count is -1 indexed (0 means revision has 1 existing edit; revision = *index* of timeline action)
			ur_type = UR_REDO
			action = Global.actions[rev] # redoing a manual add(0) adds the note(still 0), redoing a manual delete(1) deletes the note(still 1).
			Global.revision += 1
			ur_handler()

## Dew's favorite child :)
func ur_handler() -> void:
	Global.in_ur = true
	print("UR entered with action: ", action,"!") #[add, del, drag, paste]
	print("Global.revision: ", Global.revision," which acts on revision #: ", rev)
	#print("Selected data:", Global.changes[rev])
	#print("Expected format: ",Global.revision_format[action])
	match action:
		Global.ACTION_ADD:
			for note in Global.changes[rev]:
				print("UR adding!")
				add_child(note[REF])    # simply shows a hidden note
				note[REF].bar = note[OLD]
		Global.ACTION_DELETE:
			for note in Global.changes[rev]:
				print("UR deleting!")
				clearing_notes = true
				remove_child(note[REF]) # simply hides a select note
				clearing_notes = false
				note[REF].bar = -69420
		Global.ACTION_DRAG:
			if ur_type == UR_UNDO:
				for note in Global.changes[rev]:
					print("UR dragging (undo)!")
					stuffed_note = note[REF]
					add_note(false, note[OLD][0], note[OLD][1], note[OLD][2], note[OLD][3])
			else: # redo
				for note in Global.changes[rev]:
					print("UR dragging (redo)!")
					stuffed_note = note[REF]
					add_note(false, note[NEW][0], note[NEW][1], note[NEW][2], note[NEW][3])
		Global.ACTION_PASTE: # paste desired note(s)
			var notes_new = Global.changes[rev][ur_type]
			print("URing the copypasta (replace)!")
			if notes_new.size() > 0:
				clearing_notes = true
				for note in notes_new:
					add_child(note)
					print("confirm new note at bar: ",note.bar)
				clearing_notes = false
			ur_type = !ur_type
			print(ur_type)
			var notes_old = Global.changes[rev][ur_type]
			print("URing the copypasta (remove)!")
			if notes_old.size() > 0:
				clearing_notes = true
				for note in notes_old:
					remove_child(note)
					print("removed old note at bar: ",note.bar)
				clearing_notes = false
	ur_type = UR_NONE
	update_note_array()
	Global.in_ur = false


func redraw_notes() -> void:
	for child in get_children():
		if child is not Note: continue
		if child.is_in_view:
			child.show()
			child.resize_handles()
			# TODO why were we doing this, notes already update their neighbors on every edit
			# with this disabled, notes that were created on chart load still have neighbors set
			# all this seems to have been doing is slamming perf when scrolling huge charts
			#child.update_touching_notes()
		else:
			if !child.visible && child.position.x - (Note.BARHANDLE_SIZE.x/2) >= scroll_end:
				return # we have reached the end of notes we needed to hide
			child.hide()


func _on_tmb_updated(defer:bool=true) -> void:
	bar_spacing = tmb.savednotespacing * %ZoomLevel.value
	if defer: _update_queued = true
	else: _do_tmb_update()

func _do_tmb_update() -> void:
	custom_minimum_size.x = (tmb.endpoint + 1) * bar_spacing
	%SectionStart.max_value = tmb.endpoint
	%SectionLength.max_value = tmb.endpoint - %SectionStart.value
	%PlayheadPos.max_value = tmb.endpoint
	%LyricsEditor._update_lyrics()
	%Settings._update_handles()
	for note in get_children():
		if note is not Note || note.is_queued_for_deletion():
			continue
		note.position.x = note.bar * bar_spacing
		# TODO ditto with comment in redraw_notes(), this was causing spikes
		#if !note.touching_notes.has(Note.END_IS_TOUCHING): note.update_slide_idx()
	queue_redraw()
	redraw_notes()
	_update_queued = false


func to_snapped(pos:Vector2) -> Vector2:
	var new_bar = x_to_bar( pos.x )
	var timing_snap = 1.0 / settings.timing_snap
	var pitch = -height_to_pitch( pos.y )
	var pitch_snap = Global.SEMITONE / settings.pitch_snap
	return Vector2(
		clamp(
			snapped( new_bar, timing_snap ),
			0, tmb.endpoint
			),
		clamp(
			snapped( pitch, pitch_snap, ),
			Global.SEMITONE * -13, Global.SEMITONE * 13
			)
		)
func to_unsnapped(pos:Vector2):
	return Vector2(
		x_to_bar(pos.x),
		-height_to_pitch(pos.y)
	)


func timing_snap_changed(_value:float) -> void: queue_redraw()


func _on_tmb_loaded() -> void:
	var children := get_children()
	clearing_notes = true
	for i in children.size():
		var child = children[-(i + 1)]
		if child is Note: child.queue_free()
	await(get_tree().process_frame)
	clearing_notes = false
	
	doot_enabled = false
	for note in tmb.notes:
		add_note(false,
				note[TMBInfo.NOTE_BAR],
				note[TMBInfo.NOTE_LENGTH],
				note[TMBInfo.NOTE_PITCH_START],
				note[TMBInfo.NOTE_PITCH_DELTA]
		)
	doot_enabled = %DootToggle.button_pressed
	_on_tmb_updated()

func add_note(start_drag:bool, bar:float, length:float, pitch:float, pitch_delta:float = 0.0) -> void:
	var note : Note
	if ur_type == UR_NONE: note = note_scn.instantiate()
	else: note = stuffed_note # Dew: don't create a new note if we're mid-U/R action; we track pre-existing notes via Global.changes when we remove them.
	
	note.bar = bar
	note.length = length
	note.pitch_start = pitch
	note.pitch_delta = pitch_delta
	note.position.x = bar_to_x(bar)
	note.position.y = pitch_to_height(pitch)
	note.dragging = Note.DRAG_INITIAL if start_drag else Note.DRAG_NONE
	
	doot(pitch)
	if Global.in_ur && settings.length.value < tmb.get_last_note_off():
		settings.length.value = max(2,ceilf(tmb.get_last_note_off()))
	if ur_type == UR_NONE: add_child(note) # Dew: We don't want to re-add the child to the parent if the data was only changed via drag; it's still on-screen.
	else: return
	note.grab_focus()
	note._set_handle_tooltips()

# move to ???
func continuous_note_overlaps(time:float, length:float, exclude : Array = []) -> bool:
	var is_in_range := func(value: float, range_start:float, range_end:float):
		return value > range_start && value < range_end
	
	for note in Global.working_tmb.notes:
		var bar = note[TMBInfo.NOTE_BAR]
		var end = note[TMBInfo.NOTE_BAR] + note[TMBInfo.NOTE_LENGTH]
		if bar in exclude: continue
		for value in [bar, end]:
			if is_in_range.call(value,time,time+length): return true
		# we need to test the middle of the note so that notes of the same length
		# don't think it's fine if they start and end at the same time
		for value in [time, time + length, time + (length / 2.0)]:
			if is_in_range.call(value,bar,end): return true
	
	return false


func update_note_array() -> void:
	var new_array := []
	###Dew timeline tracker
	print("action timeline: ",Global.actions)
	print("terminal revision: ",Global.revision)
	###
	for child in get_children():
		var note := child as Note
		if note == null || note.is_queued_for_deletion() || note.bar < 0: continue
		
		var note_array := note.as_array()
		new_array.append(note_array)
	new_array.sort_custom(func(a,b): return a[TMBInfo.NOTE_BAR] < b[TMBInfo.NOTE_BAR])
	tmb.notes = new_array
	settings.ensure_valid_endpoint()
	queue_redraw()
	redraw_notes()
	chart_updated.emit()


func jump_to_note(note: int, use_tt: bool = false) -> void:
	var count = 0
	var children = get_children()
	if not use_tt: children.sort_custom(func(a, b): return a.position.x < b.position.x)
	for child in children:
		if child is not Note: continue
		count += 1
		if use_tt and note != child.tt_note_id: continue
		elif not use_tt and count != note: continue
		else:
			%ChartView.set_h_scroll(int(child.position.x - (%ChartView.size.x / 2)))
			redraw_notes()
			queue_redraw()
			child.grab_focus()
			break

func assign_tt_note_ids() -> void:
	var count = 0
	var children = %Chart.get_children()
	children.sort_custom(func(a, b): return a.position.x < b.position.x)
	for child in children:
		if child is not Note: continue
		count += 1
		child.tt_note_id = count


func _draw() -> void:
	var font : Font = ThemeDB.get_fallback_font()
	if tmb == null: return
	var section_rect = Rect2(bar_to_x(settings.section_start), 1,
			bar_to_x(settings.section_length), size.y)
	draw_rect(section_rect, Color(0.3, 0.9, 1.0, 0.1))
	draw_rect(section_rect, Color.CORNFLOWER_BLUE, false, 3.0)
	var rect_bumps_pos = Vector2(section_rect.position.x+0.5,size.y/2+3)
	draw_line(rect_bumps_pos+Vector2(-5,-5),
			rect_bumps_pos+Vector2(0,-5),Color.CORNFLOWER_BLUE,3.0)
	draw_line(rect_bumps_pos+Vector2(-5,5),
			rect_bumps_pos+Vector2(0,5),Color.CORNFLOWER_BLUE,3.0)
	rect_bumps_pos.x += section_rect.size.x
	draw_line(rect_bumps_pos+Vector2(0,-5),
			rect_bumps_pos+Vector2(4,-5),Color.CORNFLOWER_BLUE,3.0)
	draw_line(rect_bumps_pos+Vector2(0,5),
			rect_bumps_pos+Vector2(4,5),Color.CORNFLOWER_BLUE,3.0)
	if %PreviewController.is_playing:
		if settings.section_length:
			draw_line(Vector2(bar_to_x(%PreviewController.song_position),0),
					Vector2(bar_to_x(%PreviewController.song_position),size.y),
					Color.CORNFLOWER_BLUE, 2 )
		else: settings.playhead_pos = %PreviewController.song_position
	# Draw bar lines
	for i in tmb.endpoint + 1:
		var line_x = i * bar_spacing
		var next_line_x = (i + 1) * bar_spacing
		if (line_x < scroll_position) && (next_line_x < scroll_position): continue
		if line_x > scroll_end: break
		draw_line(Vector2(line_x, 0), Vector2(line_x, size.y),
				Color.WHITE if !(i % tmb.timesig)
				else Color(1,1,1,0.33) if bar_spacing > 20.0
				else Color(1,1,1,0.15), 2
			)
		var subdiv = %TimingSnap.value
		for j in subdiv:
			if i == tmb.endpoint || bar_spacing < 20.0: break
			if j == 0.0: continue
			var k = 1.0 / subdiv
			var line = i + (k * j)
			draw_line(Vector2(line * bar_spacing, 0), Vector2(line * bar_spacing, size.y),
					Color(0.7,1,1,0.2) if bar_spacing > 20.0
					else Color(0.7,1,1,0.1),
					1 )
		if !(i % tmb.timesig):
			@warning_ignore("integer_division")
			draw_string(font, Vector2(i * bar_spacing, 0) + Vector2(8, 16),
					str(i / tmb.timesig), HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
			draw_string(font, Vector2(i * bar_spacing, 0) + Vector2(8, 32),
					str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	# End drawing bar lines
	if show_preview:
		var mouse_pos = get_local_mouse_position()
		if Rect2(Vector2.ZERO,size).has_point(mouse_pos):
			draw_line(Vector2(mouse_pos.x,0), Vector2(mouse_pos.x,size.y),
						Color.ORANGE_RED, 1 )
		# no way to change the delay on a per-node basis, it seems
		ProjectSettings.set_setting('gui/timers/tooltip_delay_sec', 0)
		tooltip_text = ("%.4f" % x_to_bar(mouse_pos.x)).rstrip('0.')
	else:
		ProjectSettings.set_setting('gui/timers/tooltip_delay_sec', 0.5)
		tooltip_text = ""
	var playhead_pos = Vector2(bar_to_x(%PlayheadPos.value),0)
	draw_line(playhead_pos,
			playhead_pos + Vector2.DOWN*size.y,
			Color.ORANGE_RED, 2.0)
	if !%PreviewController.is_playing:
		var play_symbol_size := 10.0
		var play_symbol := [ playhead_pos,
							playhead_pos + Vector2(play_symbol_size/1.33, play_symbol_size/2),
							playhead_pos + Vector2(0, play_symbol_size) ]
		draw_colored_polygon(play_symbol, Color.ORANGE_RED)
		draw_polyline(play_symbol, Color.ORANGE_RED,0.5,true)


func count_onscreen_notes() -> int: # currently unused
	var accum := 0
	for child in get_children():
		if (child is Note && child.is_in_view): accum += 1
	return accum

func update_playhead(event) -> void:
	var bar = x_to_bar(event.position.x)
	if settings.snap_time: bar = snapped(bar,current_subdiv)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Since the Chart node is currently handling this input event
				# Godot won't change the cursor shape when the playhead moves
				# so I'm manually setting it here
				mouse_default_cursor_shape = CURSOR_POINTING_HAND
				settings.playhead_pos = bar
			else:
				mouse_default_cursor_shape = CURSOR_ARROW
	elif event is InputEventMouseMotion: queue_redraw()
	# Forward the input event to the handle here otherwise the user will
	# need to re-click to move the playhead further.
	var mouse_pos = %PlayheadHandle.get_local_mouse_position()
	event.position = mouse_pos
	%PlayheadHandle._gui_input(event)

func _gui_input(event) -> void:
	if event is InputEventPanGesture:
		# Used for two finger scrolling on trackpads
		_on_scroll_change()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN \
		|| event.button_index == MOUSE_BUTTON_WHEEL_UP \
		|| event.button_index == MOUSE_BUTTON_WHEEL_LEFT \
		|| event.button_index == MOUSE_BUTTON_WHEEL_RIGHT:
			if Input.is_key_pressed(KEY_CTRL):
				match event.button_index:
					MOUSE_BUTTON_WHEEL_DOWN: %ZoomLevel.value -= 0.1
					MOUSE_BUTTON_WHEEL_UP: %ZoomLevel.value += 0.1
					_: pass
			_on_scroll_change()
	if Input.is_action_pressed("hold_drag_playhead"):
		update_playhead(event)
		return
	match mouse_mode:
		SELECT_MODE:
			# this isn't as clean as i'd like but i didn't want to rewrite everything
			var bar = %Chart.x_to_bar(event.position.x)
			if bar < 0:
				bar = 0
			if settings.snap_time: bar = snapped(bar, current_subdiv)
			if event is InputEventMouseButton && event.button_index == MOUSE_BUTTON_LEFT && event.pressed:
				prev_section_start = bar
				settings.section_start = bar
				settings.section_length = 0
			elif event is InputEventMouseButton && event.button_index == MOUSE_BUTTON_LEFT && !event.pressed:
				prev_section_start = settings.section_start
			elif event is InputEventMouseMotion && event.pressure:
				if %Chart.x_to_bar(event.position.x) < prev_section_start:
					settings.section_length = prev_section_start - bar
					settings.section_start = bar
				else:
					settings.section_length = bar - settings.section_start
		EDIT_MODE: # (default)
			event = event as InputEventMouseButton
			if event == null || !event.pressed: return
			if event.button_index == MOUSE_BUTTON_LEFT && !%PreviewController.is_playing:
				var new_note_pos = Vector2() # explicitly constructs a default Vector2 as opposed to only defining variable type
				if settings.snap_time: new_note_pos.x = to_snapped(event.position).x
				else: new_note_pos.x = to_unsnapped(event.position).x
				# Current length of tap notes
				var note_length = 0.0625 if settings.tap_notes else current_subdiv
				
				if new_note_pos.x == tmb.endpoint: new_note_pos.x -= (1.0 / settings.timing_snap)
				if continuous_note_overlaps(new_note_pos.x, note_length): return
				
				if settings.snap_pitch: new_note_pos.y = to_snapped(event.position).y
				else: new_note_pos.y = clamp(to_unsnapped(event.position).y,
						Global.SEMITONE * -13, Global.SEMITONE * 13)
				add_note(true, new_note_pos.x, note_length, new_note_pos.y)
				### Dew note add check ###
				Global.clear_future_edits()
				Global.actions.append(0) # Record edit as an added note. The note's script will append the *self* reference to Global.changes.
				Global.revision += 1
				Global.fresh = true
				###
				%LyricsEditor.move_to_front()
				%PlayheadHandle.move_to_front()

func _notification(what) -> void:
	match what:
		NOTIFICATION_RESIZED:
			for note in get_children():
				if note is Note && !note.is_queued_for_deletion():
					note._update()
			_on_scroll_change()


func _on_doot_toggle_toggled(toggle:bool) -> void: doot_enabled = toggle

func _on_show_targets_toggled(_toggle:bool) -> void:
	for note in get_children(): note.queue_redraw()

func _on_mouse_exited() -> void:
	show_preview = false
	queue_redraw()

func _on_note_tooltips_toggled(_toggle:bool) -> void:
	for note in get_children(): if note is Note: note._set_handle_tooltips()
