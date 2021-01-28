--Resize - main.lua--
--DEBUG CONTROLS-------------------------------
local debugmode = false 

if debugmode then
  _AUTO_RELOAD_DEBUG = true
end

local debugvars = {
  print_notifier_attachments = false,
  print_notifier_triggers = false,
  print_restorations = false, --prints restorations of existing notes to terminal when set true
  print_valuefield = false, --prints info from valuefields when set true
  clocks = false, --prints out profiling clocks in different parts of the code when set true
  clocktotals = {},
  tempclocks = {}
}

local function resetclock(num)
  if debugvars.clocks then
    debugvars.clocktotals[num] = 0
  end
end

local function setclock(num)
  if debugvars.clocks then
    debugvars.tempclocks[num] = os.clock()
  end
end

local function addclock(num)
  if debugvars.clocks then    
    debugvars.clocktotals[num] = debugvars.clocktotals[num] + (os.clock() - debugvars.tempclocks[num])
  end
end

local function readclock(num,msg)
  if debugvars.clocks then
    print(msg .. debugvars.clocktotals[num] or "nil")
  end 
end

--"GLOBALS"---------------------------------------------------------------------
local app = renoise.app() 
local tool = renoise.tool()
local song = nil

local vb = renoise.ViewBuilder() 
local vb_data = {
  window_obj = nil,
  window_title = "Resize",
  window_content = nil,
  default_margin = 0,
  sliders_width = 22,
  sliders_height = 127,
  multipliers_size = 23,
  notifiers_active = false
}

local selection
local valid_selection
local selected_seq
local selected_pattern
local originally_visible_note_columns = {}
local columns_overflowed_into = {}
local column_to_end_on_in_first_track
local is_note_track = {} --bools indicating if the track at that index supports note columns
local selected_notes = {}
local total_delay_range
local total_line_range
local earliest_placement
local latest_placement
local placed_notes = {}

local resize_flags = {
  overflow = true,
  condense = false,
  redistribute = false
}

local pattern_lengths = {} --an array of []{length, valid, notifier}
local seq_length = { length = 0, valid = false }

local time = 0
local time_multiplier = 1
local time_was_typed = false
local typed_time = 1

local offset = 0
local offset_multiplier = 1
local offset_was_typed = false
local typed_offset = 0

local anchor = 0  -- 0 = top, 1 = bottom
local anchor_type = 1 -- 1 = note, 2 = selection


--RESET VARIABLES------------------------------
local function reset_variables()
  
  if not song then song = renoise.song() end
  table.clear(originally_visible_note_columns)
  table.clear(columns_overflowed_into)
  
  table.clear(selected_notes)
  
  time = 0
  time_multiplier = 1
  time_was_typed = false
  typed_time = 1
  
  offset = 0
  offset_multiplier = 1
  offset_was_typed = false
  typed_offset = 0
  
  anchor = 0
  anchor_type = 1
  
  earliest_placement = 1
  latest_placement = 0
  
  resize_flags = {   
    overflow = true,
    condense = false,
    redistribute = false
  }
  
  return(true)
end

--RESET VIEW------------------------------------------
local function reset_view()

  vb_data.notifiers_active = false

  vb.views.time_slider.value = time
  vb.views.time_multiplier_rotary.value = time_multiplier
  vb.views.offset_slider.value = offset
  vb.views.offset_multiplier_rotary.value = offset_multiplier
  vb.views.overflow_flag_checkbox.value = resize_flags.overflow
  vb.views.condense_flag_checkbox.value = resize_flags.condense
  vb.views.redistribute_flag_checkbox.value = resize_flags.redistribute
  vb.views.anchor_switch.value = anchor + 1
  vb.views.anchor_type_switch.value = anchor_type
  
  vb_data.notifiers_active = true

  return(true)
end

--DEACTIVATE CONTROLS-------------------------------------
local function deactivate_controls()
  
  if vb_data.window_obj then
    vb.views.time_text.active = false
    vb.views.time_slider.active = false
    vb.views.time_multiplier_rotary.active = false
    vb.views.overflow_flag_checkbox.active = false
    vb.views.offset_text.active = false
    vb.views.offset_slider.active = false
    vb.views.offset_multiplier_rotary.active = false
    vb.views.overflow_flag_checkbox.active = false
    vb.views.condense_flag_checkbox.active = false
    vb.views.redistribute_flag_checkbox.active = false
  end

  return(true)
end

--ACTIVATE CONTROLS-------------------------------------
local function activate_controls()
  
  if vb_data.window_obj then
    vb.views.time_text.active = true
    vb.views.time_slider.active = true
    vb.views.time_multiplier_rotary.active = true
    vb.views.offset_text.active = true
    vb.views.offset_slider.active = true
    vb.views.offset_multiplier_rotary.active = true
    vb.views.overflow_flag_checkbox.active = true
    vb.views.condense_flag_checkbox.active = true
    vb.views.redistribute_flag_checkbox.active = true
  end

  return(true)
end

--INVALIDATE SELECTION-------------------------------------
local function invalidate_selection()

  --invalidate selection
  valid_selection = false
  
  deactivate_controls()

end
  
--RELEASE DOCUMENT------------------------------------------
local function release_document()

  if debugvars.print_notifier_triggers then print("release document notifier triggered!") end
  
  --invalidate selection
  invalidate_selection()
  
  --invalidate recorded sequence length
  seq_length.valid = false
  
  --invalidate all recorded pattern lengths
  for k, v in pairs(pattern_lengths) do    
    v.valid = false
  end
  
end  
  
--NEW DOCUMENT------------------------------------------
local function new_document()

  if debugvars.print_notifier_triggers then print("new document notifier triggered!") end

  song = renoise.song()
  
  reset_variables()
  --reset_view()
  
end

--ADD DOCUMENT NOTIFIERS------------------------------------------------
local function add_document_notifiers()

  --add document release notifier if it doesn't exist yet
  if not tool.app_release_document_observable:has_notifier(release_document) then
    tool.app_release_document_observable:add_notifier(release_document)
    
    if debugvars.print_notifier_attachments then print("release document notifier attached!") end    
  end

  --add new document notifier if it doesn't exist yet
  if not tool.app_new_document_observable:has_notifier(new_document) then
    tool.app_new_document_observable:add_notifier(new_document)
    
    if debugvars.print_notifier_attachments then print("new document notifier attached!") end    
  end  

  return(true)
end

--STORE NOTE--------------------------------------------
local function store_note(s,p,t,c,l,counter)
  
  local column_to_store = song:pattern(p):track(t):line(l):note_column(c)
  
  if not column_to_store.is_empty then
  
    selected_notes[counter] = {}
    
    selected_notes[counter].original_index = {
      s = s,
      p = p,
      t = t,
      c = c,
      l = l
    }
    
    selected_notes[counter].note_value = column_to_store.note_value
    selected_notes[counter].instrument_value = column_to_store.instrument_value
    selected_notes[counter].volume_value = column_to_store.volume_value 
    selected_notes[counter].panning_value = column_to_store.panning_value 
    selected_notes[counter].delay_value = column_to_store.delay_value 
    selected_notes[counter].effect_number_value = column_to_store.effect_number_value 
    selected_notes[counter].effect_amount_value = column_to_store.effect_amount_value
    
    --initialize the location of the note
    selected_notes[counter].current_location = {
      s = s, 
      p = p, 
      t = t, 
      c = c, 
      l = l
    }
    
    --initialize the last location of the note
    selected_notes[counter].last_location = {
      s = s, 
      p = p, 
      t = t, 
      c = c, 
      l = l
    }
    
    --initialize empty data to replace its spot when it moves
    selected_notes[counter].last_overwritten_values = {
      note_value = 121,
      instrument_value = 255,
      volume_value = 255,
      panning_value = 255,
      delay_value = 0,
      effect_number_value = 0,
      effect_amount_value = 0
    }
    
    --initalize our flag so that the note will leave an empty space behind when it moves
    selected_notes[counter].restore_flag = true
    
    counter = counter + 1
  
  end
  
  return(counter)
end

--GET SELECTION-----------------------------------------
local function get_selection()

  --get selection
  selected_seq = song.selected_sequence_index
  selected_pattern = song.sequencer:pattern(selected_seq)
  selection = song.selection_in_pattern
  
  if not selection then
    app:show_error("no selection has been made")
    valid_selection = false
    deactivate_controls()
    return(false)
  else
    valid_selection = true
  end

  return(true)
end

--FIND NOTES IN SELECTION---------------------------------------------
local function find_selected_notes()
  
  --determine which note columns are visible
  for t = selection.start_track, selection.end_track do  
    originally_visible_note_columns[t] = song:track(t).visible_note_columns     
  end
    
  --find out what column to end on when working in the first track, based on how many tracks are selected total
  if selection.end_track - selection.start_track == 0 then
    column_to_end_on_in_first_track = math.min(selection.end_column, originally_visible_note_columns[selection.start_track])
  else
    column_to_end_on_in_first_track = originally_visible_note_columns[selection.start_track]
  end
  
  local counter = 1
  table.clear(is_note_track)
  
  --scan through lines, tracks, and columns and store all notes to be resized
  for l = selection.start_line, selection.end_line do 
     
    --work on first track
    if song:track(selection.start_track).type == 1 then
      is_note_track[selection.start_track] = true
      for c = selection.start_column, column_to_end_on_in_first_track do
        counter = store_note(selected_seq,selected_pattern,selection.start_track,c,l,counter)
      end
    end
      
    --work on middle track(s)
    if selection.end_track - selection.start_track > 1 then
      for t = selection.start_track + 1, selection.end_track - 1 do
        if song:track(t).type == 1 then
          is_note_track[t] = true
          for c = 1, originally_visible_note_columns[t] do        
            counter = store_note(selected_seq,selected_pattern,t,c,l,counter)  
          end 
        end
      end
    end
      
    --work on last track--
    if selection.end_track - selection.start_track > 0 then
      if song:track(selection.end_track).type == 1  then
        is_note_track[selection.end_track] = true
        for c = 1, math.min(selection.end_column, originally_visible_note_columns[selection.end_track]) do
          counter = store_note(selected_seq,selected_pattern,selection.end_track,c,l,counter)
        end
      end
    end
    
  end
    
  return(true)
end

--REMAP RANGE-------------------------------------------------------
local function remap_range(val,lo1,hi1,lo2,hi2)

  return lo2 + (hi2 - lo2) * ((val - lo1) / (hi1 - lo1))

end

--CALCULATE NOTE PLACEMENTS------------------------------------------
local function calculate_note_placements()
  
  --total range is calculated from the first line, until FF of the last line
  total_delay_range = (selection.end_line - selection.start_line) * 256 + 255
  total_line_range = total_delay_range / 256
  
  --calculate original note placements in our selection range for each note
  for k in ipairs(selected_notes) do
    
    local line_difference = selected_notes[k].original_index.l - selection.start_line 
     
    local delay_difference = selected_notes[k].delay_value + (line_difference*256)
      
    local note_place = delay_difference / total_delay_range
    
    --store the placement value for this note (a value from 0 - 1 in selection range)
    selected_notes[k].placement = note_place
    
    --record the earliest and latest note placements in the selection
    if note_place < earliest_placement then earliest_placement = note_place end
    if note_place > latest_placement then latest_placement = note_place end
  
  end
  
  --calculate redistributed placements in selection range
  local amount_of_notes = #selected_notes
  for k in ipairs(selected_notes) do
    selected_notes[k].redistributed_placement_in_sel_range = remap_range(
      (k - 1) / amount_of_notes,
      0,
      total_line_range / (selection.end_line - selection.start_line + 1),
      0,
      1)
  end
  
  --calculate redistributed placements in note range
  for k in ipairs(selected_notes) do
    selected_notes[k].redistributed_placement_in_note_range = remap_range(
      (k - 1) / (amount_of_notes - 1),
      0,
      1,
      earliest_placement,
      latest_placement)
      
      --if there is only one note, we need to set it to 0 here, or it will be left as nan
      if amount_of_notes == 1 then selected_notes[k].redistributed_placement_in_note_range = 0 end
  end
  
  return(true)
end

--ADD PATTERN LENGTH NOTIFIER-----------------------------------
local function add_pattern_length_notifier(p)

  --define the notifier function
  local function pattern_length_notifier()
    
    if debugvars.print_notifier_triggers then
      print(("pattern %i's length notifier triggered!!"):format(p))
    end
    
    pattern_lengths[p].valid = false
    
    --remove it from our record of which pattern length notifiers we currently have attached
    pattern_lengths[p].notifier = false
  
    song.patterns[p].number_of_lines_observable:remove_notifier(pattern_length_notifier)
    
  end
  
  --then add it to the pattern in question
  song.patterns[p].number_of_lines_observable:add_notifier(pattern_length_notifier)
  
  --add it to our record of which pattern length notifiers we currently have attached
  pattern_lengths[p].notifier = true

end

--GET PATTERN LENGTH AT SEQ-----------------------------------------
local function get_pattern_length_at_seq(s)
  
  --convert the sequence index to a pattern index
  local p = song.sequencer:pattern(s)
  
  --create an entry for this pattern if there is none yet
  if not pattern_lengths[p] then  
    pattern_lengths[p] = {}
  end
  
  --update our records of this pattern's length if we don't have the valid data for it
  if not pattern_lengths[p].valid then
    pattern_lengths[p].length = song.patterns[p].number_of_lines
    pattern_lengths[p].valid = true  
    
    --add our notifier to invalidate our recorded pattern length if this pattern's length changes
    add_pattern_length_notifier(p)
    
    if debugvars.print_notifier_attachments then
      print(("pattern %i's length notifier attached!!"):format(p))
    end
  end
  
  return(pattern_lengths[s].length)
end

--SEQUENCE COUNT NOTIFIER---------------------------------------------------
local function sequence_count_notifier()
  
  if debugvars.print_notifier_triggers then print("sequence count notifier triggered!!") end
  
  seq_length.valid = false
  
  song.sequencer.pattern_sequence_observable:remove_notifier(sequence_count_notifier)
  
end

--GET SEQUENCE LENGTH-------------------------------------
local function get_sequence_length()

  if not seq_length.valid then
    seq_length.length = #song.sequencer.pattern_sequence
    seq_length.valid = true
    
    --add our notifier to invalidate our recorded seq length if the sequence length changes
    song.sequencer.pattern_sequence_observable:add_notifier(sequence_count_notifier)
    
    if debugvars.print_notifier_attachments then print("sequence count notifier attached!!") end
  end
  
  return(seq_length.length)
end

--IS STORABLE-----------------------------------------
local function is_storable(index,counter)

  if not placed_notes[index.p] then return true end
  if not placed_notes[index.p][index.t] then return true end
  if not placed_notes[index.p][index.t][index.l] then return true end
  if not placed_notes[index.p][index.t][index.l][index.c] then return true--return true if no notes were found to be storing data at this spot
  else return false end --return false if we found one of our notes already in this spot
  
end

--FIND CORRECT INDEX---------------------------------------
local function find_correct_index(original_index, new_line)
  
  --shorten variables
  local s,p,t,c,l = original_index.s, original_index.p, original_index.t, original_index.c, new_line
  
  --find the correct sequence if our line index lies before or after the bounds of this pattern
  if l < 1 then  
    while l < 1 do
    
      --decrement the sequence index (with wrap-around)
      s = (s - 1) % get_sequence_length()
      if s == 0 then s = get_sequence_length() end
        
      --update our line index
      l = l + get_pattern_length_at_seq(s)
        
    end  
  elseif l > get_pattern_length_at_seq(s) then
    while true do
      
      --update our line index
      l = l - get_pattern_length_at_seq(s)
      
      --increment the sequence index (with wrap-around)
      s = (s + 1) % get_sequence_length()
      if s == 0 then s = get_sequence_length() end
            
      --break the loop if we find a valid line index
      if l <= get_pattern_length_at_seq(s) then break end
            
    end      
  end
  
  --get the new pattern index based on our new sequence index
  p = song.sequencer:pattern(s)
  
  --if overflow is on, then push notes out to empty columns when available
  if resize_flags.overflow then
    while true do
      if c == 12 then break
      elseif song:pattern(p):track(t):line(l):note_column(c).is_empty then break
      else c = c + 1 end
    end
    
    --record which columns we overflowed into (set to 0 if we didn't overflow at all)
    if not columns_overflowed_into[t] then columns_overflowed_into[t] = 0 end
    columns_overflowed_into[t] = math.max(columns_overflowed_into[t], c)        
  end
  
  
  --if condense is on, then pull notes in to empty columns when available
  if resize_flags.condense then
    while true do
      if c == 1 then break
      elseif not song:pattern(p):track(t):line(l):note_column(c-1).is_empty then break
      else c = c - 1 end
    end
  end
  
  
  
  --return the note column we need
  local column = song:pattern(p):track(t):line(l):note_column(c)
  
  --return the new p,t,c,l values as well
  local new_index = {s = s, p = p, t = t, c = c, l = l}
  
  return column, new_index
end

--SET TRACK VISIBILITY------------------------------------------
local function set_track_visibility(t)
  
  if not columns_overflowed_into[t] then columns_overflowed_into[t] = 0 end
  
  local columns_to_show = math.max(columns_overflowed_into[t], originally_visible_note_columns[t])
  
  song:track(t).visible_note_columns = columns_to_show

end

--SET NOTE COLUMN VALUES----------------------------------------------
local function set_note_column_values(column,new_values)

  column.note_value = new_values.note_value
  column.instrument_value = new_values.instrument_value
  column.volume_value = new_values.volume_value
  column.panning_value = new_values.panning_value
  column.delay_value = new_values.delay_value
  column.effect_number_value = new_values.effect_number_value
  column.effect_amount_value = new_values.effect_amount_value

end

--RESTORE OLD NOTE----------------------------------------------
local function restore_old_note(counter)

  --access the ptcl values we will be indexing
  local restore_index = {
    p = selected_notes[counter].current_location.p,
    t = selected_notes[counter].current_location.t,
    c = selected_notes[counter].current_location.c,
    l = selected_notes[counter].current_location.l
  }
  
  --[[
  --clear the column clean
  song:pattern(restore_index.p):track(restore_index.t):line(restore_index.l):note_column(restore_index.c):clear()
  --]]
  
  --exit this function here if this note is not supposed to restore anything
  if not selected_notes[counter].restore_flag then 
    if debugvars.print_restorations then
      print(("not restoring note %i because it's flag is set false!"):format(counter))
    end
    return 
  end   
    
  if debugvars.print_restorations then
    print(("restoring note %i because it's flag is set true!"):format(counter))
  end
    
  --access the column we will need to restore
  local column_to_restore = song:pattern(restore_index.p):track(restore_index.t):line(restore_index.l):note_column(restore_index.c)
  
  --access the values to restore
  local stored_note_values = selected_notes[counter].last_overwritten_values
  
  --restore the note
  set_note_column_values( column_to_restore, stored_note_values)
  
  return true
end

--GET EXISTING NOTE----------------------------------------------
local function get_existing_note(index,counter)

  --access the new column that we need to store
  local column_to_store = song:pattern(index.p):track(index.t):line(index.l):note_column(index.c)

  --if this spot is not empty, and is not already occupied by our own notes...
  if (not column_to_store.is_empty) and (not is_storable(index,counter)) then
    
    selected_notes[counter].restore_flag = false  --set this note's flag to false
    
  else  --otherwise, if it is a note that should be stored...

setclock(8)
  
    selected_notes[counter].restore_flag = true  --set this note's flag to true
      
    --and store the data from the column we're overwriting
    selected_notes[counter].last_overwritten_values = {
      note_value = column_to_store.note_value,
      instrument_value = column_to_store.instrument_value,
      volume_value = column_to_store.volume_value,
      panning_value = column_to_store.panning_value,
      delay_value = column_to_store.delay_value,
      effect_number_value = column_to_store.effect_number_value,
      effect_amount_value = column_to_store.effect_amount_value
    }

addclock(8)
    
  end
  
end

--UPDATE CURRENT NOTE LOCATION----------------------------------------
local function update_current_note_location(counter,new_index)
  
  --update the current location of the note
  selected_notes[counter].current_location.p = new_index.p
  selected_notes[counter].current_location.t = new_index.t
  selected_notes[counter].current_location.c = new_index.c
  selected_notes[counter].current_location.l = new_index.l
  
end

--ADD TO PLACED NOTES-----------------------------------------
local function add_to_placed_notes(index,counter)

  --create the table(s) at the specified index if they do not yet exist
  if not placed_notes[index.p] then placed_notes[index.p] = {} end
  if not placed_notes[index.p][index.t] then placed_notes[index.p][index.t] = {} end
  if not placed_notes[index.p][index.t][index.l] then placed_notes[index.p][index.t][index.l] = {} end
  
  --set the index equal to the number of the note that has been put in it
  placed_notes[index.p][index.t][index.l][index.c] = counter

end

--PLACE NEW NOTE----------------------------------------------
local function place_new_note(counter)

setclock(2)

  --decide which time value to use (typed or sliders)
  local time_to_use
  if time_was_typed then time_to_use = typed_time
  else time_to_use = time * time_multiplier + 1 end
  
  --decide which offset value to use (typed or sliders)
  local offset_to_use
  if offset_was_typed then offset_to_use = typed_offset
  else offset_to_use = offset * offset_multiplier end
  
  
  --set our anchor for where "x0.0" would end up when resizing, 0 - 1 in our selection range
  local anchor_to_use
  if anchor_type == 1 then
    if anchor == 0 then anchor_to_use = earliest_placement  
    else anchor_to_use = latest_placement end
  else
    if anchor == 0 then anchor_to_use = 0   
    else anchor_to_use = 1 end
  end
  
  
  local placement
  if resize_flags.redistribute then --if redistribution flag is set, we use the redistributed places
    if anchor_type == 1 then
      placement = selected_notes[counter].redistributed_placement_in_note_range
    else
      placement = selected_notes[counter].redistributed_placement_in_sel_range
    end
  else  --otherwise, we use the original placements
    placement = selected_notes[counter].placement
  end
  
  --recalculate our placements based on our new anchor
  placement = placement - anchor_to_use
  
  --apply our time and offset values to our placement value
  placement = placement * time_to_use + offset_to_use
  
  --calculate the indexes where the new note will be, based on its new placement value
  local delay_difference = placement * total_delay_range + anchor_to_use * total_delay_range
  local new_delay_value = (delay_difference % 256)
  local line_difference = math.floor(delay_difference / 256)
  local new_line = selection.start_line + line_difference
  
addclock(2)
setclock(3)
  
  local column, new_index = find_correct_index(selected_notes[counter].original_index, new_line)  
  
addclock(3)
setclock(4)
  
  --store the note from the new spot we have moved to
  get_existing_note(new_index, counter)

addclock(4)
setclock(5)
  
  update_current_note_location(counter, new_index)

addclock(5)
  
  local note_values = {
    note_value = selected_notes[counter].note_value,
    instrument_value = selected_notes[counter].instrument_value,
    volume_value = selected_notes[counter].volume_value,
    panning_value = selected_notes[counter].panning_value,
    delay_value = selected_notes[counter].delay_value,
    effect_number_value = selected_notes[counter].effect_number_value,
    effect_amount_value = selected_notes[counter].effect_amount_value
  }  
  

  
  note_values.delay_value = new_delay_value
  
setclock(6)
  
  set_note_column_values(column, note_values)
  
addclock(6)
  
  --add note to our placed_notes table
  add_to_placed_notes(new_index,counter)


  
end

--UPDATE VALUEFIELDS---------------------------------
local function update_valuefields()

  if time_was_typed then
    vb.views.time_text.value = typed_time
  else
    vb.views.time_text.value = time * time_multiplier + 1
  end
  
  if offset_was_typed then
    vb.views.offset_text.value = typed_offset
  else
    vb.views.offset_text.value = (offset * offset_multiplier) * (total_line_range)
  end
  
end

--APPLY RESIZE------------------------------------------
local function apply_resize()
  
  if not valid_selection then
    app:show_error("There is no valid selection to operate on!")
    deactivate_controls()
    return(false)
  end
  
  table.clear(columns_overflowed_into)
  
  --restore everything to how it was, so we don't run into our own notes during calculations
  for k in ipairs(selected_notes) do
    restore_old_note(k)
  end
  
  --clear our "placed_notes" table so we can lay them down one by one cleanly
  table.clear(placed_notes)

for i = 1, 9 do
resetclock(i)
end
setclock(1)
  
  --place our notes into place one by one
  for k in ipairs(selected_notes) do
    place_new_note(k)
  end

readclock(2,"clock2: ")
readclock(3,"find_correct_index clock: ")
readclock(4,"get_existing_note clock: ")
readclock(5,"update_current_note_location clock: ")
readclock(6,"set_note_column_values clock: ")
--readclock(7,"is_storable clock: ") --removed
readclock(8,"storing notes clock: ")

addclock(1)
readclock(1,"place_new_note total clock: ")
  
  --show delay columns and note columns...
  --for first track
  if is_note_track[selection.start_track] then
    song:track(selection.start_track).delay_column_visible = true
    set_track_visibility(selection.start_track)
  end
  
  --for all middle tracks
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do 
      if is_note_track[t] then     
        --show delay column
        song:track(t).delay_column_visible = true     
        --update note column visibility
        set_track_visibility(t)
      end
    end
  end  
  
  --and for the last track
  if is_note_track[selection.end_track] then
    --show delay column
    song:track(selection.end_track).delay_column_visible = true  
    --update note column visibility
    set_track_visibility(selection.end_track)
  end
  
  --update our multiplier text
  update_valuefields()
  
end


--if performance becomes a problem, we can use add_resize_idle_notifier() instead of apply_resize()
--for now, we will use apply_resize() though, as performance is pretty good, and feels good to have changes be fluid

--[[
--APPLY RESIZE NOTIFIER----------------------------------
local function apply_resize_notifier()
    
  apply_resize()
  
  tool.app_idle_observable:remove_notifier(apply_resize_notifier)
  
  if debugvars.print_notifier_triggers then print("idle notifier triggered!") end
end

--ADD RESIZE IDLE NOTIFIER--------------------------------------
local function add_resize_idle_notifier()
  
  
  if not tool.app_idle_observable:has_notifier(apply_resize_notifier) then
    tool.app_idle_observable:add_notifier(apply_resize_notifier)
  
    if debugvars.print_notifier_attachments then print("idle notifier attached!") end
  end

end
--]]

--REPOSITION CONTROLS----------------------------------------------
local function reposition_controls()

  vb_data.notifiers_active = false
  
  vb.views.time_slider.value = -vb.views.time_slider.value
  
  vb_data.notifiers_active = true

end

--SHOW WINDOW---------------------------------------------------- 
local function show_window()

  --prepare the window content if it hasn't been done yet
  if not vb_data.window_content then    
    vb_data.window_content = vb:column {
      width = 160,
      
      vb:horizontal_aligner {
        mode = "center",
        width = 160,
      
        vb:vertical_aligner {
          mode = "center",
          width = 32,
          
          vb:valuefield {
            id = "time_text",
            align = "center",
            min = -999,
            max = 999,
            value = 1,
            
            --tonumber converts any typed-in user input to a number value 
            --(called only if value was typed)
            tonumber = function(str)
              local val = str:gsub("[^0-9.-]", "") --filter string to get numbers and decimals
              val = tonumber(val) --this tonumber() is Lua's basic string-to-number converter
              if val and -999 <= val and val <= 999 then --if val is a number, and within min/max
                if debugvars.print_valuefield then print("tonumber = " .. val) end
                typed_time = val
                time_was_typed = true                     
                apply_resize()
              end
              return val
            end,
            
            --tostring is called when field is clicked, 
            --after tonumber is called,
            --and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(value)
              if debugvars.print_valuefield then print(("tostring = x%.4f"):format(value)) end
              return ("x%.4f"):format(value)
            end,        
            
            --notifier is called whenever the value is changed
            notifier = function(value)
            if debugvars.print_valuefield then print("notifier") end
            end
          },
          
          vb:minislider {    
            id = "time_slider", 
            tooltip = "Time", 
            min = -1, 
            max = 1, 
            value = time, 
            width = vb_data.sliders_width, 
            height = vb_data.sliders_height, 
            notifier = function(value)
              if anchor == 0 then
                time = -value
              else
                time = value
              end
              if vb_data.notifiers_active then
                time_was_typed = false
                apply_resize() 
              end
            end    
          },
        
          vb:rotary { 
            id = "time_multiplier_rotary", 
            tooltip = "Time Multiplier", 
            min = 1, 
            max = 64, 
            value = time_multiplier, 
            width = vb_data.multipliers_size, 
            height = vb_data.multipliers_size, 
            notifier = function(value) 
              time_multiplier = value
              if vb_data.notifiers_active then
                time_was_typed = false
                apply_resize()
              end
            end 
          }        
        },
        
        vb:vertical_aligner {
          mode = "center",
          width = 32,
          
          vb:valuefield {
            id = "offset_text",
            align = "center",
            min = -999,
            max = 999,
            value = 0,
            
            --tonumber converts any typed-in user input to a number value 
            --(called only if value was typed)
            tonumber = function(str)
              local val = str:gsub("[^0-9.-]", "") --filter string to get numbers and decimals
              val = tonumber(val) --this tonumber() is Lua's basic string-to-number converter
              if val and -999 <= val and val <= 999 then --if val is a number, and within min/max
                if debugvars.print_valuefield then print("tonumber = " .. val) end
                typed_offset = val / (total_line_range)
                offset_was_typed = true
                apply_resize()
              end
              return val
            end,
            
            --tostring is called when field is clicked, 
            --after tonumber is called,
            --and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(value)
              if debugvars.print_valuefield then print(("tostring = %.1f lines"):format(value)) end
              return ("%.1f lines"):format(value)
            end,        
            
            --notifier is called whenever the value is changed
            notifier = function(value)
            if debugvars.print_valuefield then print("notifier") end
            end
          },
          
          vb:minislider {    
            id = "offset_slider", 
            tooltip = "Offset", 
            min = -1, 
            max = 1, 
            value = 0, 
            width = vb_data.sliders_width, 
            height = vb_data.sliders_height, 
            notifier = function(value)            
              if vb_data.notifiers_active then
                offset_was_typed = false
                offset = -(value / (total_line_range))
                apply_resize()
              end
            end    
          },
          
          vb:rotary { 
            id = "offset_multiplier_rotary", 
            tooltip = "Offset Multiplier", 
            min = 1, 
            max = 64, 
            value = 1, 
            width = vb_data.multipliers_size, 
            height = vb_data.multipliers_size, 
            notifier = function(value)
              offset_was_typed = false
              offset_multiplier = value
              if vb_data.notifiers_active then
                apply_resize()
              end
            end 
          }          
        }
      },               
      
      vb:vertical_aligner {
        mode = "center",
        width = 32,
        
        vb:switch {
          id = "anchor_switch",
          width = 64,
          value = 1,
          items = {"Top", "End"},
          notifier = function(value)
            if vb_data.notifiers_active then
              anchor = value - 1
              reposition_controls()
              apply_resize()
            end
          end
        },
        vb:switch {
          id = "anchor_type_switch",
          width = 64,
          value = 1,
          items = {"Note", "Select"},
          notifier = function(value)
            anchor_type = value
            if vb_data.notifiers_active then
              apply_resize()
            end
          end
        }
      },
      
      vb:checkbox { 
        id = "overflow_flag_checkbox", 
        tooltip = "Overflow Mode",
        value = resize_flags.overflow, 
        notifier = function(value) 
          resize_flags.overflow = value
          if vb_data.notifiers_active then
            apply_resize()
          end
        end 
      },
      
      vb:checkbox { 
        id = "condense_flag_checkbox", 
        tooltip = "Condense Mode",
        value = resize_flags.condense, 
        notifier = function(value) 
          resize_flags.condense = value
          if vb_data.notifiers_active then
            apply_resize()
          end
        end 
      },
      
      vb:checkbox { 
        id = "redistribute_flag_checkbox", 
        tooltip = "Redistribute Mode",
        value = resize_flags.redistribute, 
        notifier = function(value) 
          resize_flags.redistribute = value
          if vb_data.notifiers_active then
            apply_resize()
          end
        end 
      }   
             
    }
  end
  
  --create/show the dialog window
  if not vb_data.window_obj or not vb_data.window_obj.visible then
    vb_data.window_obj = app:show_custom_dialog(vb_data.window_title, vb_data.window_content)
  else vb_data.window_obj:show()
  end  
  
  return(true)
end

--SELECTION-BASED STRUM-----------------------------------------------
local function resize_selection()
      
  local result = reset_variables()
  if result then result = get_selection() end
  if result then result = find_selected_notes() end
  if result then result = calculate_note_placements() end
  if result then result = add_document_notifiers() end
  if result then result = show_window() end
  if result then result = activate_controls() end
  update_valuefields()
  if result then result = reset_view() end

end

--MENU/HOTKEY ENTRIES-------------------------------------------------------------------------------- 

renoise.tool():add_menu_entry { 
  name = "Main Menu:Tools:Resize Selection...", 
  invoke = function() resize_selection() end 
}

renoise.tool():add_menu_entry { 
  name = "Pattern Editor:Resize Selection...", 
  invoke = function() resize_selection() end 
}
