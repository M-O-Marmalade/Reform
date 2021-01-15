--Strum - main.lua--
--DEBUG CONTROLS-------------------------------
local debugmode = true 

if debugmode then
  _AUTO_RELOAD_DEBUG = true
end

local debugvars = {
  clear_pattern_one = true,
  print_notifier_attachments = true,
  print_notifier_triggers = true
}

--GLOBALS-------------------------------------------------------------------------------------------- 
local app = renoise.app() 
local tool = renoise.tool()
local song = nil

local vb = renoise.ViewBuilder() 
local vb_data = {
  window_obj = nil,
  window_title = "Strum",
  window_content = nil,
  default_margin = 0,
  sliders_width = 22,
  sliders_height = 127,
  multipliers_size = 23,
}

local selection
local valid_selection
local selected_seq
local selected_pattern
local visible_note_columns = {}
local column_to_end_on_in_first_track
local notes_in_selection = {}
local total_delay_range

local resize_flags = {
  vol = true,
  pan = true,
  fx = true,
  overflow = true,
  condense = false
}

local pattern_lengths = {} --an array of []{length, valid, notifier}
local seq_length = { length = 0, valid = false }

local time = 0
local time_min = -1
local time_max = 1

local time_multiplier = 1
local time_multiplier_min = 1
local time_multiplier_max = 64


--RESET VARIABLES------------------------------
local function reset_variables()
  
  if not song then song = renoise.song() end
  visible_note_columns = {}
  notes_in_selection = {}
  
  time = 0
  time_multiplier = 1
  
  resize_flags = {
    vol = true,
    pan = true,
    fx = true,
    overflow = true,
    condense = false
  }
  
  return(true)
end

--RESET VIEW------------------------------------------
local function reset_view()

  vb.views.time_slider.value = time
  vb.views.time_multiplier_rotary.value = time_multiplier
  vb.views.vol_flag_checkbox.value = resize_flags.vol
  vb.views.pan_flag_checkbox.value = resize_flags.pan
  vb.views.fx_flag_checkbox.value = resize_flags.fx
  vb.views.overflow_flag_checkbox.value = resize_flags.overflow
  vb.views.condense_flag_checkbox.value = resize_flags.condense

  return(true)
end
  
--RELEASE DOCUMENT------------------------------------------
local function release_document()

  if debugvars.print_notifier_triggers then print("release document notifier triggered!") end
  
  --invalidate selection
  valid_selection = false
  
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
  reset_view()
  
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
local function store_note(p,t,c,l)
  
  local column = song:pattern(p):track(t):line(l):note_column(c)
  
  if not column.is_empty then
  
    if not notes_in_selection[p] then notes_in_selection[p] = {} end
    if not notes_in_selection[p][t] then notes_in_selection[p][t] = {} end
    if not notes_in_selection[p][t][c] then notes_in_selection[p][t][c] = {} end
    if not notes_in_selection[p][t][c][l] then notes_in_selection[p][t][c][l] = {} end
  
    notes_in_selection[p][t][c][l][1] = column.note_value
    notes_in_selection[p][t][c][l][2] = column.instrument_value
    notes_in_selection[p][t][c][l][3] = column.volume_value 
    notes_in_selection[p][t][c][l][4] = column.panning_value 
    notes_in_selection[p][t][c][l][5] = column.delay_value 
    notes_in_selection[p][t][c][l][6] = column.effect_number_value 
    notes_in_selection[p][t][c][l][7] = column.effect_amount_value 
  
  end
  
  return(true)
end

--FIND NOTES IN SELECTION---------------------------------------------
local function find_notes_in_selection()

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
  
  --determine which note columns are visible
  for t = selection.start_track, selection.end_track do  
    visible_note_columns[t] = song:track(t).visible_note_columns     
  end
    
  --find out what column to end on when working in the first track, based on how many tracks are selected total
  if selection.end_track - selection.start_track == 0 then
    column_to_end_on_in_first_track = math.min(selection.end_column, visible_note_columns[selection.start_track])
  else
    column_to_end_on_in_first_track = visible_note_columns[selection.start_track]
  end
  
  --work on first track--
  for c = selection.start_column, column_to_end_on_in_first_track do
    for l = selection.start_line, selection.end_line do
      store_note(selected_pattern,selection.start_track,c,l)       
    end
  end
  
  --work on middle tracks--
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do
      for c = 1, visible_note_columns[t] do
        for l = selection.start_line, selection.end_line do
          store_note(selected_pattern,t,c,l)  
        end      
      end    
    end
  end
  
  --work on last track--
  if selection.end_track - selection.start_track > 0 then
    for c = 1, math.min(selection.end_column, visible_note_columns[selection.end_track]) do
      for l = selection.start_line, selection.end_line do
        store_note(selected_pattern,selection.end_track,c,l)    
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

--CALCULATE SINGLE NOTE PLACEMENT------------------------------------------
local function calculate_single_note_placement(p,t,c,l)

  --check if this note was empty/nil, and if so, return from this function without doing anything
  if not notes_in_selection[p] or
  not notes_in_selection[p][t] or
  not notes_in_selection[p][t][c] or
  not notes_in_selection[p][t][c][l] then
    return
  end
    
  local line_difference = l - selection.start_line
  
  local delay_difference = notes_in_selection[p][t][c][l][5] + (line_difference*256)
  
  local note_place = delay_difference / total_delay_range
    
  notes_in_selection[p][t][c][l][8] = note_place
    
  return(true)
end

--CALCULATE NOTE PLACEMENTS------------------------------------------
local function calculate_note_placements()

  --work on first track--
  for c = selection.start_column, column_to_end_on_in_first_track do
    for l = selection.start_line, selection.end_line do
      calculate_single_note_placement(selected_pattern,selection.start_track,c,l)
    end
  end
  
  --work on middle tracks--
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do
      for c = 1, visible_note_columns[t] do
        for l = selection.start_line, selection.end_line do
          calculate_single_note_placement(selected_pattern,t,c,l)     
        end      
      end    
    end
  end
  
  --work on last track--
  if selection.end_track - selection.start_track > 0 then
    for c = 1, math.min(selection.end_column, visible_note_columns[selection.end_track]) do
      for l = selection.start_line, selection.end_line do
        calculate_single_note_placement(selected_pattern,selection.end_track,c,l)   
      end
    end
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

--FIND CORRECT INDEX---------------------------------------
local function find_correct_index(s,p,t,c,l)
  
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
  
  p = song.sequencer:pattern(s)
  
  local column
  --if overflow is on, then push notes out to empty columns when available
  if resize_flags.overflow then
    while true do
      if c == 12 then break
      elseif song:pattern(p):track(t):line(l):note_column(c).is_empty then break
      else c = c + 1 end
    end
    --expand the visible note columns to show the overflowed notes
    if c > visible_note_columns[t] then 
      song:track(t).visible_note_columns = c
    end
  else
    --if overflow isn't active, we should only show the columns that were originally visible
    song:track(t).visible_note_columns = visible_note_columns[t]
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
  return(song:pattern(p):track(t):line(l):note_column(c))
end

--PLACE NEW NOTE----------------------------------------------
local function place_new_note(p,t,c,l)
  
  --check if this note was empty/nil, and if so, return from this function without doing anything
  if not notes_in_selection[p] or
  not notes_in_selection[p][t] or
  not notes_in_selection[p][t][c] or
  not notes_in_selection[p][t][c][l] then
    return
  end
  
  --calculate the indexes where the new note will be, based on its placement value
  local new_placement = notes_in_selection[p][t][c][l][8] * (time * time_multiplier + 1)
    
  local new_delay_difference = new_placement*total_delay_range
   
  local new_line_difference = math.floor(new_delay_difference / 256)
    
  local new_delay_value = new_delay_difference%256
    
  local new_line = selection.start_line + new_line_difference
  
  local column = find_correct_index(selected_seq,p,t,c,new_line)
  
  --place the note
  column.note_value = notes_in_selection[p][t][c][l][1]
  column.instrument_value = notes_in_selection[p][t][c][l][2]
  if resize_flags[1] then column.volume_value = notes_in_selection[p][t][c][l][3] end
  if resize_flags[2] then column.panning_value = notes_in_selection[p][t][c][l][4] end
  column.delay_value = new_delay_value
  if resize_flags[3] then column.effect_number_value = notes_in_selection[p][t][c][l][6] end
  if resize_flags[3] then column.effect_amount_value = notes_in_selection[p][t][c][l][7] end
  
end

--STRUM SELECTION------------------------------------------
local function strum_selection()

  if debugvars.clear_pattern_one then
    song:pattern(1):clear()
  end
  
  if not valid_selection then
    app:show_error("There is no valid selection to operate on!")
    return(false)
  end
  
  --WORK ON FIRST TRACK--
  for c = selection.start_column, column_to_end_on_in_first_track do
    for l = selection.start_line, selection.end_line do
      place_new_note(selected_pattern,selection.start_track,c,l)
    end
  end
  --show delay column for this track
  song:track(selection.start_track).delay_column_visible = true
  
  --WORK ON MIDDLE TRACKS (if there are more than two tracks)--  
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do
      for c = 1, visible_note_columns[t] do
        for l = selection.start_line, selection.end_line do
          place_new_note(selected_pattern,t,c,l)     
        end      
      end 
      --show delay column for each middle track
      song:track(t).delay_column_visible = true   
    end
  end
  
  --WORK ON LAST TRACK (if there is more than one track)--
  if selection.end_track - selection.start_track > 0 then
    for c = 1, math.min(selection.end_column, visible_note_columns[selection.end_track]) do
      for l = selection.start_line, selection.end_line do
        place_new_note(selected_pattern,selection.end_track,c,l)   
      end
    end
    --show delay column for this track
    song:track(selection.end_track).delay_column_visible = true  
  end

  return(true)
end

--SHOW WINDOW---------------------------------------------------- 
local function show_window()

  --prepare the window content if it hasn't been done yet
  if not vb_data.window_content then    
    vb_data.window_content = vb:column {
  
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
        strum_selection()
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
          strum_selection()
        end 
      },
        
      vb:checkbox { 
        id = "vol_flag_checkbox", 
        tooltip = "Volume Flag",
        value = true, 
        notifier = function(value) 
          resize_flags[1] = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "pan_flag_checkbox", 
        tooltip = "Panning Flag",
        value = true, 
        notifier = function(value) 
          resize_flags[2] = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "fx_flag_checkbox", 
        tooltip = "FX Flag",
        value = true, 
        notifier = function(value) 
          resize_flags[3] = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "overflow_flag_checkbox", 
        tooltip = "Overflow Flag",
        value = true, 
        notifier = function(value) 
          resize_flags.overflow = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "condense_flag_checkbox", 
        tooltip = "Condense Flag",
        value = true, 
        notifier = function(value) 
          resize_flags.condense = value
          strum_selection()
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
  if result then result = find_notes_in_selection() end
  if result then result = calculate_range() end
  if result then result = calculate_note_placements() end
  if result then result = add_document_notifiers() end
  if result then result = show_window() end      
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
