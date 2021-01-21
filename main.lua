--Resize - main.lua--
--DEBUG CONTROLS-------------------------------
local debugmode = true 

if debugmode then
  _AUTO_RELOAD_DEBUG = true
end

local debugvars = {
  clear_pattern_one = false,
  print_notifier_attachments = false,
  print_notifier_triggers = false,
  print_restorations = false,
  print_valuefield = true
}

--GLOBALS-------------------------------------------------------------------------------------------- 
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
  multipliers_size = 23  
}

local selection
local valid_selection
local selected_seq
local selected_pattern
local originally_visible_note_columns = {}
local columns_overflowed_into = {}
local column_to_end_on_in_first_track
local selected_notes = {}
local total_delay_range

local resize_flags = {
  overflow = true,
  condense = false,
  redistribute = false
}

local pattern_lengths = {} --an array of []{length, valid, notifier}
local seq_length = { length = 0, valid = false }

local time = 0
local time_min = -1
local time_max = 1

local time_multiplier = 1
local time_multiplier_min = 1
local time_multiplier_max = 64

local value_was_typed = false


--RESET VARIABLES------------------------------
local function reset_variables()
  
  if not song then song = renoise.song() end
  originally_visible_note_columns = {} 
  columns_overflowed_into = {} 
  
  selected_notes = {}
  
  time = 0
  time_multiplier = 1
  
  resize_flags = {   
    overflow = true,
    condense = false,
    redistribute = false
  }
  
  return(true)
end

--RESET VIEW------------------------------------------
local function reset_view()

  vb.views.time_slider.value = time
  vb.views.time_multiplier_rotary.value = time_multiplier
  vb.views.overflow_flag_checkbox.value = resize_flags.overflow
  vb.views.condense_flag_checkbox.value = resize_flags.condense

  return(true)
end

--DEACTIVATE CONTROLS-------------------------------------
local function deactivate_controls()

  vb.views.time_slider.active = false
  vb.views.time_multiplier_rotary.active = false
  vb.views.overflow_flag_checkbox.active = false
  vb.views.condense_flag_checkbox.active = false
  vb.views.redistribute_flag_checkbox.active = false

  return(true)
end

--ACTIVATE CONTROLS-------------------------------------
local function activate_controls()

  vb.views.time_slider.active = true
  vb.views.time_multiplier_rotary.active = true
  vb.views.overflow_flag_checkbox.active = true
  vb.views.condense_flag_checkbox.active = true
  vb.views.redistribute_flag_checkbox.active = true

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
  
  --work on first track--
  for l = selection.start_line, selection.end_line do
    for c = selection.start_column, column_to_end_on_in_first_track do
      counter = store_note(selected_seq,selected_pattern,selection.start_track,c,l,counter)       
    end
  end
  
  --work on middle tracks--
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do
      for l = selection.start_line, selection.end_line do      
        for c = 1, originally_visible_note_columns[t] do        
          counter = store_note(selected_seq,selected_pattern,t,c,l)  
        end      
      end    
    end
  end
  
  --work on last track--
  if selection.end_track - selection.start_track > 0 then
    for l = selection.start_line, selection.end_line do
      for c = 1, math.min(selection.end_column, originally_visible_note_columns[selection.end_track]) do
        counter = store_note(selected_seq,selected_pattern,selection.end_track,c,l)    
      end
    end
  end
    
  return(true)
end

--CALCULATE RANGE------------------------------------------
local function calculate_range()

  total_delay_range = (selection.end_line - (selection.start_line - 1))*256

  return(true)
end

--CALCULATE NOTE PLACEMENTS------------------------------------------
local function calculate_note_placements()
  
  --calculate original placements
  for k in ipairs(selected_notes) do
    
    local line_difference = selected_notes[k].original_index.l - selection.start_line
  
    local delay_difference = selected_notes[k].delay_value + (line_difference*256)
  
    local note_place = delay_difference / total_delay_range
    
    selected_notes[k].placement = note_place
  
  end    
  
  --calculate redistributed placements
  local amount_of_notes = #selected_notes
  for k in ipairs(selected_notes) do
    selected_notes[k].redistributed_placement = (k - 1) / amount_of_notes
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

  for k in pairs(selected_notes) do
    if (selected_notes[k].current_location.p == index.p and
    selected_notes[k].current_location.t == index.t and
    selected_notes[k].current_location.c == index.c and
    selected_notes[k].current_location.l == index.l) then
      if k ~= counter then
        if selected_notes[k].is_placed then     
          return false  --return false if we found a note matching this spot
        end
      end
    end    
  end
  
  --return true if no notes were found to be storing data at this spot
  return true
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
  
  if not is_storable(index,counter) then  --if this spot is already occupied by our own notes...
    
    selected_notes[counter].restore_flag = false  --set this note's flag to false
    
  else  --otherwise, if it is a "wild" note, or an empty spot, then
  
    selected_notes[counter].restore_flag = true
    
    --access the new column that we need to store
    local column_to_store = song:pattern(index.p):track(index.t):line(index.l):note_column(index.c)
      
    --store the data from the column we're overwriting
    selected_notes[counter].last_overwritten_values = {
      note_value = column_to_store.note_value,
      instrument_value = column_to_store.instrument_value,
      volume_value = column_to_store.volume_value,
      panning_value = column_to_store.panning_value,
      delay_value = column_to_store.delay_value,
      effect_number_value = column_to_store.effect_number_value,
      effect_amount_value = column_to_store.effect_amount_value
    }
    
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

--PLACE NEW NOTE----------------------------------------------
local function place_new_note(counter)
  
  --calculate the indexes where the new note will be, based on its placement value
  local placement_to_use
  if resize_flags.redistribute then 
    placement_to_use = selected_notes[counter].redistributed_placement
  else
    placement_to_use = selected_notes[counter].placement
  end
  local new_placement = placement_to_use * (time * time_multiplier + 1)    
  local new_delay_difference = new_placement*total_delay_range   
  local new_line_difference = math.floor(new_delay_difference / 256)    
  local new_delay_value = new_delay_difference%256    
  local new_line = selection.start_line + new_line_difference
  
  local column, new_index = find_correct_index(selected_notes[counter].original_index, new_line)  
  
  --store the note from the new spot we have moved to
  get_existing_note(new_index, counter)
  
  update_current_note_location(counter, new_index)
  
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
  
  set_note_column_values(column, note_values)
  
  --set note's "is_placed" flag to true
  selected_notes[counter].is_placed = true
  
end

--UPDATE MULTIPLIER TEXT---------------------------------
local function update_multiplier_text()

  vb.views.multiplier_text.value = (time * time_multiplier + 1)

end

--APPLY RESIZE------------------------------------------
local function apply_resize()
  
  print("apply_resize()")
  
  if not valid_selection then
    app:show_error("There is no valid selection to operate on!")
    return(false)
  end
  
  columns_overflowed_into = {}
  
  if value_was_typed then
    
  else
    
  end
  
  --restore everything to how it was, so we don't run into our own notes during calculations
  for k in ipairs(selected_notes) do
    restore_old_note(k)
  end
  
  --clear all notes' "is_placed" flags so we can lay them down one by one cleanly
  for k in ipairs(selected_notes) do
    selected_notes[k].is_placed = false
  end
  
  --place our notes into place one by one
  for k in ipairs(selected_notes) do
    place_new_note(k)
  end  
  
  --show delay columns and note columns...
  --for first track
  song:track(selection.start_track).delay_column_visible = true  
  --for all middle tracks
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do      
      --show delay column
      song:track(t).delay_column_visible = true     
      --update note column visibility
      set_track_visibility(t)    
    end
  end  
  --and for the last track
  --show delay column
  song:track(selection.end_track).delay_column_visible = true  
  --update note column visibility
  set_track_visibility(selection.end_track)
  
  --update our multiplier text
  update_multiplier_text()
  
end

--SHOW WINDOW---------------------------------------------------- 
local function show_window()

  --prepare the window content if it hasn't been done yet
  if not vb_data.window_content then    
    vb_data.window_content = vb:column {
            
      vb:valuefield {
        id = "multiplier_text",
        align = "center",
        min = -999,
        max = 999,
        value = 1,
        
        --tonumber converts any typed-in user input to a number value 
        --(called only if value was typed)
        tonumber = function(str)
          local val = str:gsub("[^0-9.-]", "")
          val = tonumber(val) --this tonumber() is Lua's basic string-to-number converter function
          if val and -999 <= val and val <= 999 then --if val is a number, and within min/max range
            if debugvars.print_valuefield then print("tonumber = " .. val) end
            local temptime = time
            local temptime_multiplier = time_multiplier 
            time = val - 1
            time_multiplier = 1                       
            apply_resize()
            time = temptime
            time_multiplier = temptime_multiplier
          end
          return val
        end,
        
        --tostring is called when field is clicked, 
        --after tonumber is called,
        --and after the notifier is called
        --it converts the value to a formatted string to be displayed
        tostring = function(value)
          if debugvars.print_valuefield then print(("tostring = x%.04f"):format(value)) end
          return ("x%.04f"):format(value)
        end,        
        
        --notifier is called whenever the value is changed
        notifier = function(value)
        if debugvars.print_valuefield then print("notifier") end
        end
      },
      
      vb:minislider {    
      id = "time_slider", 
      tooltip = "The time over which to spread the notes", 
      min = time_min, 
      max = time_max, 
      value = time, 
      width = vb_data.sliders_width, 
      height = vb_data.sliders_height, 
      notifier = function(value)
        time = -value
        apply_resize()
      end    
      },
      
      vb:rotary { 
        id = "time_multiplier_rotary", 
        tooltip = "Time multiplier", 
        min = time_multiplier_min, 
        max = time_multiplier_max, 
        value = time_multiplier, 
        width = vb_data.multipliers_size, 
        height = vb_data.multipliers_size, 
        notifier = function(value) 
          time_multiplier = value
          apply_resize()
        end 
      },              
      
      vb:checkbox { 
        id = "overflow_flag_checkbox", 
        tooltip = "Overflow Flag",
        value = resize_flags.overflow, 
        notifier = function(value) 
          resize_flags.overflow = value
          apply_resize()
        end 
      },
      
      vb:checkbox { 
        id = "condense_flag_checkbox", 
        tooltip = "Condense Flag",
        value = resize_flags.condense, 
        notifier = function(value) 
          resize_flags.condense = value
          apply_resize()
        end 
      },
      
      vb:checkbox { 
        id = "redistribute_flag_checkbox", 
        tooltip = "Redistribute Flag",
        value = resize_flags.redistribute, 
        notifier = function(value) 
          resize_flags.redistribute = value
          apply_resize()
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
  if result then result = calculate_range() end
  if result then result = calculate_note_placements() end
  if result then result = add_document_notifiers() end
  if result then result = show_window() end
  if result then result = activate_controls() end    
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
