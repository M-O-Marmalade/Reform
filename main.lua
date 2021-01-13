--Strum - main.lua--
--DEBUG CONTROLS-------------------------------
local debugmode = true 

if debugmode then
  _AUTO_RELOAD_DEBUG = true
end

local debugvars = {
  create_note_offs_on_find = false,
  create_note_offs_on_calculate_single_note = false,
  print_note_placements = false,
  print_new_note_placements = false,
  clear_pattern_one = true
}

--GLOBALS-------------------------------------------------------------------------------------------- 
local app = renoise.app() 
local tool = renoise.tool()
local song = nil

local vb = renoise.ViewBuilder() 
local window_obj = nil
local window_title = "Strum" 
local window_content = nil 
local default_margin = 0
local sliders_width = 22
local sliders_height = 127
local multipliers_size = 23

local selected_seq
local selected_pattern
local selection

local visible_note_columns = {}
local column_to_end_on_in_first_track

local notes_in_selection = {}
local total_delay_range

local column_flags = {
  true, --vol
  true, --pan
  true  --fx
}

local overflow_flag = true
local condense_flag = true

local time = 1
local time_max = 4

local time_multiplier = 1
local time_multiplier_max = 64

--CLEAR VARIABLES------------------------------
local function clear_variables()

  song = renoise.song()
  visible_note_columns = {}
  notes_in_selection = {}
  
  return(true)
end

--CREATE NOTE-OFF--------------------------------
local function create_note_off(p,t,c,l)

  song:pattern(p):track(t):line(l):note_column(c).note_value = 120

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
    return(false)
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
      
      if debugvars.create_note_offs_on_find then
        create_note_off(selected_pattern,selection.start_track,c,l)
      end           
    end
  end
  
  --work on middle tracks--
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do
      for c = 1, visible_note_columns[t] do
        for l = selection.start_line, selection.end_line do
          store_note(selected_pattern,t,c,l)   
          
          if debugvars.create_note_offs_on_find then
            create_note_off(selected_pattern,t,c,l)
          end          
        end      
      end    
    end
  end
  
  --work on last track--
  if selection.end_track - selection.start_track > 0 then
    for c = 1, math.min(selection.end_column, visible_note_columns[selection.end_track]) do
      for l = selection.start_line, selection.end_line do
        store_note(selected_pattern,selection.end_track,c,l) 
        
        if debugvars.create_note_offs_on_find then
          create_note_off(selected_pattern,selection.end_track,c,l)
        end        
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

  if debugvars.create_note_offs_on_calculate_single_note then
    create_note_off(p,t,c,l)
  end
    
  local line_difference = l - selection.start_line
  
  local delay_difference = notes_in_selection[p][t][c][l][5] + (line_difference*256)
  
  local note_place = delay_difference / total_delay_range
    
  notes_in_selection[p][t][c][l][8] = note_place
    
  if debugvars.print_note_placements then
    print(("pattern %i, track %i, column %i, line %i, placement: %f"):format(p,t,c,l,note_place))
  end    
    
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
  
  local column = song:pattern(p):track(t):line(new_line):note_column(c)
  
  --if overflow is on, then push notes out to empty columns when available
  if overflow_flag then
    local i = 1
    while not column.is_empty do
      if c+i > 12 then break end
      column = song:pattern(p):track(t):line(new_line):note_column(c+i)
      i = i + 1
    end
  end
  
  --if condense is on, then pull notes in to empty columns when available
  if condense_flag then
    local i = 1
    while column.is_empty do
      if c-i < 1 or not song:pattern(p):track(t):line(new_line):note_column(c-i).is_empty then break end
      column = song:pattern(p):track(t):line(new_line):note_column(c-i)
      i = i + 1
    end
  end
  
  --place the note
  column.note_value = notes_in_selection[p][t][c][l][1]
  column.instrument_value = notes_in_selection[p][t][c][l][2]
  if column_flags[1] then column.volume_value = notes_in_selection[p][t][c][l][3] end
  if column_flags[2] then column.panning_value = notes_in_selection[p][t][c][l][4] end
  column.delay_value = new_delay_value
  if column_flags[3] then column.effect_number_value = notes_in_selection[p][t][c][l][6] end
  if column_flags[3] then column.effect_amount_value = notes_in_selection[p][t][c][l][7] end
    
  if debugvars.print_new_note_placements then
    print(("pattern %i, track %i, column %i, line %i, new placement: %f"):format(p,t,c,l, new_placement))
  end

end

--STRUM SELECTION------------------------------------------
local function strum_selection()

  if debugvars.clear_pattern_one then
    song:pattern(1):clear()
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
  if not window_content then    
    window_content = vb:column {
  
      vb:minislider {    
      id = "time_slider", 
      tooltip = "The time over which to spread the notes", 
      min = -time_max, 
      max = time_max, 
      value = 0, 
      width = sliders_width, 
      height = sliders_height, 
      notifier = function(value)
        time = -value
        strum_selection()
      end    
      },
      
      vb:rotary { 
        id = "time_multiplier", 
        tooltip = "Time multiplier", 
        min = 1, 
        max = time_multiplier_max, 
        value = 1, 
        width = multipliers_size, 
        height = multipliers_size, 
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
          column_flags[1] = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "pan_flag_checkbox", 
        tooltip = "Panning Flag",
        value = true, 
        notifier = function(value) 
          column_flags[2] = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "fx_flag_checkbox", 
        tooltip = "FX Flag",
        value = true, 
        notifier = function(value) 
          column_flags[3] = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "overflow_flag_checkbox", 
        tooltip = "Overflow Flag",
        value = true, 
        notifier = function(value) 
          overflow_flag = value
          strum_selection()
        end 
      },
      
      vb:checkbox { 
        id = "condense_flag_checkbox", 
        tooltip = "Condense Flag",
        value = true, 
        notifier = function(value) 
          condense_flag = value
          strum_selection()
        end 
      }  
          
    }
  end
  
  --create/show the dialog window
  if not window_obj or not window_obj.visible then
    window_obj = app:show_custom_dialog(window_title, window_content)
  else window_obj:show()
  end  
  
  return(true)
end

--SELECTION-BASED STRUM-----------------------------------------------
local function selection_based_strum()
  local result = clear_variables()
  if result then result = find_notes_in_selection() end
  if result then result = calculate_range() end
  if result then result = calculate_note_placements() end
  if result then result = show_window() end

end

--MENU/HOTKEY ENTRIES-------------------------------------------------------------------------------- 

renoise.tool():add_menu_entry { 
  name = "Main Menu:Tools:Strum Selection...", 
  invoke = function() selection_based_strum() end 
}
