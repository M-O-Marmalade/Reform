--Reform - main.lua--

--DEBUG CONTROLS-------------------------------
_AUTO_RELOAD_DEBUG = true

local debugvars = {
  extra_curve_controls = false,
  print_notifier_attach = false,
  print_notifier_trigger = false,
  print_queue_processing = false,
  print_valuefield = false, --prints info from valuefields when set true
  print_clocks = false, --prints out profiling clocks in different parts of the code when set true
  clocktotals = {},
  tempclocks = {}
}

local function rstclk(num)
  if debugvars.print_clocks then
    debugvars.clocktotals[num] = 0
  end
end

local function stclk(num)
  if debugvars.print_clocks then
    debugvars.tempclocks[num] = os.clock()
  end
end

local function adclk(num)
  if debugvars.print_clocks then    
    debugvars.clocktotals[num] = debugvars.clocktotals[num] + (os.clock() - debugvars.tempclocks[num])
  end
end

local function rdclk(num,msg)
  if debugvars.print_clocks then
    print(msg .. debugvars.clocktotals[num] or "nil")
  end 
end

--"GLOBALS"---------------------------------------------------------------------
local app = renoise.app() 
local tool = renoise.tool()
local song = nil

local vb = renoise.ViewBuilder() 
local window_obj = nil
local window_content = nil
local vb_notifiers_on
local last_spacebar = 0
local theme = {
  selected_button_back = {255,0,0}
}

local previous_time = 0
local idle_processing = false --if apply_reform() takes longer than 40ms, this becomes true

local selected_notes = {} --contains all of our notes to be processed
--[[
  the selected_notes "struct" consists of...
  
  [1,2 .. n]{
    
    --the index where the note originated from
    original_index = {s,p,t,c,l}
    
    --original values stored from the note
    note_value
    instrument_value
    volume_value 
    panning_value
    delay_value
    effect_number_value
    effect_amount_value
    
    rel_line_pos --the line difference between current_location and original_index
    
    current_location = {s,p,t,c,l}  --the new/current index of the note after processing
    
    --precomputed placement values to use for different types of operations
    placement    
    redistributed_placement_in_note_range    
    redistributed_placement_in_sel_range
    
    --values stored from last spot this note overwrote
    last_overwritten_values = {
      note_value
      instrument_value
      volume_value
      panning_value
      delay_value
      effect_number_value
      effect_amount_value
    }
    
    flags = {      
      write --tells whether this note should overwrite whatever is at the same index as it is
      clear --tells whether this note should clear the index it is at when it leaves
      restore --tells whether this note should restore anything next time restoration occurs          
    }
    
  }
--]]

local selection
local valid_selection
local selected_seq
local selected_pattern
local originally_visible_columns = {{},{},{},{},{}}
local columns_overflowed_into = {}
local column_to_end_on_in_first_track
local is_note_track = {} --bools indicating if the track at that index supports note columns
local total_delay_range
local total_line_range
local earliest_placement
local latest_placement
local placed_notes = {}
local note_collisions = {ours = {}, wild = {}}
local start_pos = renoise.SongPos()

local flags = {
  overflow = true,
  condense = false,
  redistribute = false,
  our_notes = false,
  wild_notes = false,
  
  vol = false,
  vol_re = false,
  vol_orig_min = 0,
  vol_orig_max = 128,
  vol_min = 0,
  vol_max = 128,
  
  pan = false,
  pan_re = false,
  pan_orig_min = 0,
  pan_orig_max = 128,
  pan_min = 0,
  pan_max = 128,
  
  fx = false,
  fx_re = false,
  fx_orig_min = 0,
  fx_orig_max = 255,
  fx_min = 0,
  fx_max = 255,  
}

local pattern_lengths = {} --[pattern_index]{length, valid, notifier}
local seq_length = { length = 0, valid = false }
local visible_note_columns = {} --[track_index]{amount, valid, notifier}
local visible_effect_columns = {} --[track_index]{amount, valid, notifier}
local track_count = {} --{amount, valid, notifier}

local time = 0
local time_multiplier = 1
local time_was_typed = false
local typed_time = 1

local curve_intensity = {0, 0, 0, 0}  --time,vol,pan,fx
local curve_type = {1, 1, 1, 1}
local curve_points = {
  
  { --time
    sampled = {},
    default = {
      points = {{0,1,1},{1,0,1}},
      samplesize = 2
    },
    {
      positive = {{0,1,1},{1,1,1},{1,0,1}},
      negative = {{0,1,1},{0,0,1},{1,0,1}},
      samplesize = 19
    },
    {
      positive = {{0,1,1},{0.5,1,4},{0.5,0,4},{1,0,1}},
      negative = {{0,1,1},{0,0.5,4},{1,0.5,4},{1,0,1}},
      samplesize = 18
    }
  },
  
  { --vol
    sampled = {},
    default = {
      points = {{0,0,1},{1,1,1}},
      samplesize = 2
    },
    {
      positive = {{0,0,1},{0,1,1},{1,1,1}},
      negative = {{0,0,1},{1,0,1},{1,1,1}},
      samplesize = 10
    }
  },
  
  { --pan
    sampled = {},
    default = {
      points = {{0,0,1},{1,1,1}},
      samplesize = 2
    },
    {
      positive = {{0,0,1},{0,1,1},{1,1,1}},
      negative = {{0,0,1},{1,0,1},{1,1,1}},
      samplesize = 10
    }
  },
  
    { --fx
    sampled = {},
    default = {
      points = {{0,0,1},{1,1,1}},
      samplesize = 2
    },
    {
      positive = {{0,0,1},{0,1,1},{1,1,1}},
      negative = {{0,0,1},{1,0,1},{1,1,1}},
      samplesize = 10
    }
  },
  
}
local pascals_triangle = {}
local curve_displays = {
  { xsize = 16, ysize = 16, display = {}, buffer1 = {}, buffer2 = {} }, --time
  { xsize = 11, ysize = 11, display = {}, buffer1 = {}, buffer2 = {} }, --vol
  { xsize = 11, ysize = 11, display = {}, buffer1 = {}, buffer2 = {} }, --pan
  { xsize = 11, ysize = 11, display = {}, buffer1 = {}, buffer2 = {} }, --fx
}
local drawmode = "line"

local offset = 0
local offset_multiplier = 1
local offset_was_typed = false
local typed_offset = 0

local anchor = 0  -- 0 = top, 1 = bottom
local anchor_type = 1 -- 1 = note, 2 = selection


--RESET VARIABLES------------------------------
local function reset_variables()
  
  --get our song reference if we don't have it yet
  if not song then song = renoise.song() end
  
  originally_visible_columns = {{},{},{},{},{}}
  table.clear(columns_overflowed_into)
  table.clear(is_note_track) 
  table.clear(selected_notes)
  table.clear(placed_notes)
  
  time = 0
  time_multiplier = 1
  time_was_typed = false
  typed_time = 1
  
  curve_intensity = {0,0,0,0}
  
  offset = 0
  offset_multiplier = 1
  offset_was_typed = false
  typed_offset = 0
  
  anchor = 0
  anchor_type = 1
  
  earliest_placement = math.huge
  latest_placement = 0
  
  flags = {
    overflow = true,
    condense = false,
    redistribute = false,
    our_notes = false,
    wild_notes = false,
    
    vol = false,
    vol_re = false,
    vol_orig_min = 0,
    vol_orig_max = 128,
    vol_min = 0,
    vol_max = 128,
    
    pan = false,
    pan_re = false,
    pan_orig_min = 0,
    pan_orig_max = 128,
    pan_min = 0,
    pan_max = 128,
    
    fx = false,
    fx_re = false,
    fx_orig_min = 0,
    fx_orig_max = 255,
    fx_min = 0,
    fx_max = 255,  
  }
  
  return true
end

--RESET VIEW------------------------------------------
local function reset_view()

  vb_notifiers_on = false
  
  vb.views.time_text.value = 1
  vb.views.time_slider.value = 0
  vb.views.time_multiplier_rotary.value = time_multiplier
  vb.views.offset_text.value = offset
  vb.views.offset_slider.value = offset
  vb.views.offset_multiplier_rotary.value = offset_multiplier
  vb.views.anchor_switch.value = anchor + 1
  vb.views.anchor_type_switch.value = anchor_type
  vb.views.vol_min_box.value = flags.vol_orig_min
  vb.views.vol_max_box.value = flags.vol_orig_max
  vb.views.pan_min_box.value = flags.pan_orig_min
  vb.views.pan_max_box.value = flags.pan_orig_max
  vb.views.fx_min_box.value = flags.fx_orig_min
  vb.views.fx_max_box.value = flags.fx_orig_max
  
  vb.views.overflow_button.color = flags.overflow and theme.selected_button_back or {0,0,0}
  vb.views.condense_button.color = flags.condense and theme.selected_button_back or {0,0,0}
  vb.views.redistribute_button.color = flags.redistribute and theme.selected_button_back or {0,0,0}
  
  vb.views.vol_column.visible = false
  vb.views.volbutton.bitmap = "Bitmaps/volbutton.bmp"
  vb.views.vol_re_button.color = {0,0,0}
  
  vb.views.pan_column.visible = false
  vb.views.panbutton.bitmap = "Bitmaps/panbutton.bmp"
  vb.views.pan_re_button.color = {0,0,0}
  
  vb.views.fx_column.visible = false
  vb.views.fxbutton.bitmap = "Bitmaps/fxbutton.bmp"
  vb.views.fx_re_button.color = {0,0,0}
  
  vb_notifiers_on = true

  return true
end

--DEACTIVATE CONTROLS-------------------------------------
local function deactivate_controls()
  
  if window_obj then
    vb.views.time_text.active = false
    vb.views.time_slider.active = false
    vb.views.time_multiplier_rotary.active = false
    vb.views.offset_text.active = false
    vb.views.offset_slider.active = false
    vb.views.offset_multiplier_rotary.active = false
    vb.views.overflow_button.active = false
    vb.views.condense_button.active = false
    vb.views.redistribute_button.active = false
    vb.views.anchor_switch.active = false
    vb.views.anchor_type_switch.active = false
  end

  return true
end

--ACTIVATE CONTROLS-------------------------------------
local function activate_controls()
  
  if window_obj then
    vb.views.time_text.active = true
    vb.views.time_slider.active = true
    vb.views.time_multiplier_rotary.active = true
    vb.views.offset_text.active = true
    vb.views.offset_slider.active = true
    vb.views.offset_multiplier_rotary.active = true
    vb.views.overflow_button.active = true
    vb.views.condense_button.active = true
    vb.views.redistribute_button.active = true
    vb.views.anchor_switch.active = true
    vb.views.anchor_type_switch.active = true
  end

  return true
end
  
--RELEASE DOCUMENT------------------------------------------
local function release_document()

  if debugvars.print_notifier_trigger then print("release document notifier triggered!") end
  
  --invalidate selection
  valid_selection = false
  
  deactivate_controls()
  
  --invalidate recorded sequence length
  seq_length.valid = false
  
  --invalidate all recorded pattern lengths
  for k, v in pairs(pattern_lengths) do
    v.valid = false
  end
  
  --invalidate all recorded visible note columns for tracks
  for k, v in pairs(visible_note_columns) do
    v.valid = false
  end
  
  --invalidate all recorded visible effect columns for tracks
  for k, v in pairs(visible_effect_columns) do
    v.valid = false
  end  
  
  --invalidate recorded total track count
  track_count.valid = false
  
end  
  
--NEW DOCUMENT------------------------------------------
local function new_document()

  if debugvars.print_notifier_trigger then print("new document notifier triggered!") end

  song = renoise.song()
  
  reset_variables()
  reset_view()
  
end

--ADD DOCUMENT NOTIFIERS------------------------------------------------
local function add_document_notifiers()

  --add document release notifier if it doesn't exist yet
  if not tool.app_release_document_observable:has_notifier(release_document) then
    tool.app_release_document_observable:add_notifier(release_document)
    
    if debugvars.print_notifier_attach then print("release document notifier attached!") end    
  end

  --add new document notifier if it doesn't exist yet
  if not tool.app_new_document_observable:has_notifier(new_document) then
    tool.app_new_document_observable:add_notifier(new_document)
    
    if debugvars.print_notifier_attach then print("new document notifier attached!") end    
  end  

  return true
end

--STORE NOTE--------------------------------------------
local function store_note(s,p,t,c,l,counter)
  
  local column = song:pattern(p):track(t):line(l):note_column(c)
  
  if not column.is_empty then
    
    --create a table to store our note info
    selected_notes[counter] = {}
    
    --record the original index where the note came from
    selected_notes[counter].original_index = {
      s = s,
      p = p,
      t = t,
      c = c,
      l = l
    }
    
    --store all of the values for this note column (note,instr,vol,pan,dly,fx)
    selected_notes[counter].note_value = column.note_value
    selected_notes[counter].instrument_value = column.instrument_value
    selected_notes[counter].volume_value = column.volume_value 
    selected_notes[counter].panning_value = column.panning_value 
    selected_notes[counter].delay_value = column.delay_value 
    selected_notes[counter].effect_number_value = column.effect_number_value 
    selected_notes[counter].effect_amount_value = column.effect_amount_value
    
    --initialize the location of the note
    selected_notes[counter].current_location = {
      s = s,
      p = p,
      t = t,
      c = c,
      l = l
    }
    
    --initialize our relative line position
    selected_notes[counter].rel_line_pos = l

    --initalize our flags so that the note will leave an empty space behind when it moves
    selected_notes[counter].flags = {write = true, clear = true, restore = false}
    
    --increment our index counter by one, as we have just finished storing one new note in our table
    counter = counter + 1
  
  end
  
  return counter
end

--GET SELECTION-----------------------------------------
local function get_selection()

  --get selection box info (sequence/pattern selection is in, and selection box range)
  selected_seq = song.selected_sequence_index
  selected_pattern = song.sequencer:pattern(selected_seq)
  selection = song.selection_in_pattern
  
  --if there is no selection box, then we show an error, and disallow further operations
  if not selection then
    app:show_error("No selection has been made")
    valid_selection = false
    deactivate_controls()
    return false
  end

  return true
end

--FIND NOTES IN SELECTION---------------------------------------------
local function find_selected_notes()
  
  --determine which note columns are visible
  for t = selection.start_track, selection.end_track do  
    originally_visible_columns[1][t] = song:track(t).visible_note_columns
    originally_visible_columns[2][t] = song:track(t).volume_column_visible
    originally_visible_columns[3][t] = song:track(t).panning_column_visible
    originally_visible_columns[4][t] = song:track(t).delay_column_visible
    originally_visible_columns[5][t] = song:track(t).sample_effects_column_visible
  end
    
  --find out what column to end on when working in the first track, based on how many tracks are selected total
  if selection.end_track - selection.start_track == 0 then
    column_to_end_on_in_first_track = math.min(selection.end_column, originally_visible_columns[1][selection.start_track])
  else
    column_to_end_on_in_first_track = originally_visible_columns[1][selection.start_track]
  end
  
  local counter = 1
  table.clear(is_note_track)
  
  --scan through lines, tracks, and columns and store all notes to be reformed
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
          for c = 1, originally_visible_columns[1][t] do        
            counter = store_note(selected_seq,selected_pattern,t,c,l,counter)  
          end 
        end
      end
    end
      
    --work on last track--
    if selection.end_track - selection.start_track > 0 then
      if song:track(selection.end_track).type == 1  then
        is_note_track[selection.end_track] = true
        for c = 1, math.min(selection.end_column, originally_visible_columns[1][selection.end_track]) do
          counter = store_note(selected_seq,selected_pattern,selection.end_track,c,l,counter)
        end
      end
    end
    
  end
  
  --if no content was found in the selection, then we should not continue operations
  if counter == 1 then
    valid_selection = false
    deactivate_controls()
    app:show_error("The selection is empty!")
    return false
  end
  
  --if there was content in the selection, we will set valid_selection to true, and continue
  valid_selection = true
    
  return true
end

--REMAP RANGE-------------------------------------------------------
local function remap_range(val,lo1,hi1,lo2,hi2)
  
  if lo1 == hi1 then return lo2 end
  return lo2 + (hi2 - lo2) * ((val - lo1) / (hi1 - lo1))
end

--CALCULATE NOTE PLACEMENTS------------------------------------------
local function calculate_note_placements()
  
  --total range is calculated from the first line, until FF of the last line
  total_delay_range = (selection.end_line - selection.start_line) * 256 + 255
  total_line_range = total_delay_range / 256
  
  --calculate original note placements in our selection range for each note
  for k,note in ipairs(selected_notes) do
    
    local line_difference = note.original_index.l - selection.start_line 
     
    local delay_difference = note.delay_value + (line_difference*256)
      
    local note_place = delay_difference
    
    --store the placement value for this note (a value from 0 - total_delay_range)
    selected_notes[k].placement = note_place
    
    --record the earliest and latest note placements in the selection
    if note_place < earliest_placement then earliest_placement = note_place end
    if note_place > latest_placement then latest_placement = note_place end
  
  end
  
  --calculate redistributed placements in selection range
  local amount_of_notes = #selected_notes
  for k,note in ipairs(selected_notes) do
    note.redistributed_placement_in_sel_range = remap_range(
      (k - 1) / amount_of_notes,
      0,
      total_line_range / (selection.end_line - selection.start_line + 1),
      0,
      total_delay_range)
  end
  
  --calculate redistributed placements in note range
  for k,note in ipairs(selected_notes) do
    note.redistributed_placement_in_note_range = remap_range(
      (k - 1) / (amount_of_notes - 1),
      0,
      1,
      earliest_placement,
      latest_placement)
      
      --if there is only one note, we need to set it here, or it will be left as nan
      if amount_of_notes == 1 then note.redistributed_placement_in_note_range = earliest_placement end
  end
  
  --find the least and greatest volume values in selection
  local least_vol,greatest_vol = 128,0  
  for k,note in ipairs(selected_notes) do
    if note.volume_value > greatest_vol and note.volume_value <= 255 then
      greatest_vol = note.volume_value 
    end
    if note.volume_value < least_vol and note.volume_value <= 255 then
      least_vol = note.volume_value
    end
  end
  if least_vol == 255 then least_vol = 128 end
  if greatest_vol == 255 then greatest_vol = 128 end
  flags.vol_orig_min, flags.vol_min = least_vol, least_vol
  flags.vol_orig_max, flags.vol_max = greatest_vol, greatest_vol
  --print("least_vol: " .. least_vol)
  --print("greatest_vol: " .. greatest_vol)
  
  --find the least and greatest panning values in selection
  local least_pan,greatest_pan = 128,0  
  for k,note in ipairs(selected_notes) do    
    local pan_val = note.panning_value
    
    if pan_val == 255 then pan_val = 64 end
    
    if pan_val > greatest_pan and pan_val <= 128 then
      greatest_pan = pan_val
    end
    if pan_val < least_pan and pan_val <= 128 then
      least_pan = pan_val
    end
  end
  flags.pan_orig_min, flags.pan_min = least_pan, least_pan
  flags.pan_orig_max, flags.pan_max = greatest_pan, greatest_pan
  --print("least_pan: " .. least_pan)
  --print("greatest_pan: " .. greatest_pan)
  
    --find the least and greatest fx values in selection
  local least_fx,greatest_fx = 255,0  
  for k,note in ipairs(selected_notes) do    
    local fx_val = note.effect_amount_value
    
    if fx_val > greatest_fx and fx_val <= 255 then
      greatest_fx = fx_val
    end
    if fx_val < least_fx and fx_val <= 255 then
      least_fx = fx_val
    end
  end
  flags.fx_orig_min, flags.fx_min = least_fx, least_fx
  flags.fx_orig_max, flags.fx_max = greatest_fx, greatest_fx
  --print("least_fx: " .. least_fx)
  --print("greatest_fx: " .. greatest_fx)
  
  return true
end

--ADD PATTERN LENGTH NOTIFIER-----------------------------------
local function add_pattern_length_notifier(p)

  --define the notifier function
  local function pattern_length_notifier()
    
    if debugvars.print_notifier_trigger then
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
    
    if debugvars.print_notifier_attach then
      print(("pattern %i's length notifier attached!!"):format(p))
    end
  end
  
  return pattern_lengths[s].length
end

--SEQUENCE COUNT NOTIFIER---------------------------------------------------
local function sequence_count_notifier()
  
  if debugvars.print_notifier_trigger then print("sequence count notifier triggered!!") end
  
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
    
    if debugvars.print_notifier_attach then print("sequence count notifier attached!!") end
  end
  
  return seq_length.length
end

--TRACK COUNT NOTIFIER---------------------------------------------------
local function track_count_notifier()
  
  if debugvars.print_notifier_trigger then print("track count notifier triggered!!") end
  
  track_count.valid = false
  
  song.tracks_observable:remove_notifier(track_count_notifier)
  
end

--GET TRACK COUNT-------------------------------------
local function get_track_count()

  if not track_count.valid then
    track_count.count = #song.tracks
    track_count.valid = true
    
    --add our notifier to invalidate our recorded track count if the amount of tracks changes
    song.tracks_observable:add_notifier(track_count_notifier)
    
    if debugvars.print_notifier_attach then print("track count notifier attached!!") end
  end
  
  return track_count.count
end

--ADD VISIBLE NOTE COLUMNS NOTIFIER-----------------------------------
local function add_visible_note_columns_notifier(t)

  --define the notifier function
  local function visible_note_columns_notifier()
    
    if debugvars.print_notifier_trigger then
      print(("track %i's visible note columns notifier triggered!!"):format(t))
    end
    
    visible_note_columns[t].valid = false
    
    --remove it from our record of which notifiers we currently have attached
    visible_note_columns[t].notifier = false
  
    song:track(t).visible_note_columns_observable:remove_notifier(visible_note_columns_notifier)
    
  end
  
  --then add it to the track in question
  song:track(t).visible_note_columns_observable:add_notifier(visible_note_columns_notifier)
  
  --add it to our record of which notifiers we currently have attached
  visible_note_columns[t].notifier = true

end

--GET VISIBLE NOTE COLUMNS-----------------------------------------
local function get_visible_note_columns(t)
  
  --create an entry for this pattern if there is none yet
  if not visible_note_columns[t] then  
    visible_note_columns[t] = {}
  end
  
  --update our records of this pattern's length if we don't have the valid data for it
  if not visible_note_columns[t].valid then
    visible_note_columns[t].amount = song:track(t).visible_note_columns
    visible_note_columns[t].valid = true  
    
    --add our notifier to invalidate our record if anything changes
    add_visible_note_columns_notifier(t)
    
    if debugvars.print_notifier_attach then
      print(("track %i's visible note columns notifier attached!!"):format(t))
    end
  end
  
  return visible_note_columns[t].amount
end

--ADD VISIBLE EFFECT COLUMNS NOTIFIER-----------------------------------
local function add_visible_effect_columns_notifier(t)

  --define the notifier function
  local function visible_effect_columns_notifier()
    
    if debugvars.print_notifier_trigger then
      print(("track %i's visible effect columns notifier triggered!!"):format(t))
    end
    
    visible_effect_columns[t].valid = false
    
    --remove it from our record of which notifiers we currently have attached
    visible_effect_columns[t].notifier = false
  
    song:track(t).visible_effect_columns_observable:remove_notifier(visible_effect_columns_notifier)
    
  end
  
  --then add it to the track in question
  song:track(t).visible_effect_columns_observable:add_notifier(visible_effect_columns_notifier)
  
  --add it to our record of which notifiers we currently have attached
  visible_effect_columns[t].notifier = true

end

--GET VISIBLE EFFECT COLUMNS-----------------------------------------
local function get_visible_effect_columns(t)
  
  --create an entry for this pattern if there is none yet
  if not visible_effect_columns[t] then  
    visible_effect_columns[t] = {}
  end
  
  --update our records of this pattern's length if we don't have the valid data for it
  if not visible_effect_columns[t].valid then
    visible_effect_columns[t].amount = song:track(t).visible_effect_columns
    visible_effect_columns[t].valid = true  
    
    --add our notifier to invalidate our record if anything changes
    add_visible_effect_columns_notifier(t)
    
    if debugvars.print_notifier_attach then
      print(("track %i's visible effect columns notifier attached!!"):format(t))
    end
  end
  
  return visible_effect_columns[t].amount
end

--GET INDEX-----------------------------------
local function get_index(s,t,l,c)

  local nc,ec = nil,nil
  
  --FIND SEQUENCE INDEX
  if s then
    s = s % get_sequence_length()
    if s == 0 then s = get_sequence_length() end
  end  
  
  --FIND TRACK INDEX
  if t then
    t = t % get_track_count()
    if t == 0 then t = get_track_count() end
  end
  
  --FIND COLUMN INDEX
  if c then
    --get the total amount of visible columns for this track
    local vis_note_columns = get_visible_note_columns(t)
    local vis_effect_columns = get_visible_effect_columns(t)
    local total_vis_columns = vis_note_columns + vis_effect_columns
    
    if c > total_vis_columns then --if our desired column is outside of this track
      while c > total_vis_columns do
      
        --subtract this track's amount of note+effect columns from our column index
        c = c - total_vis_columns
        
        --increment the track index (with wrap-around)
        t = (t + 1) % get_track_count()
        if t == 0 then t = get_track_count() end
      
        --get the total amount of visible columns for this new track
        vis_note_columns = get_visible_note_columns(t)
        vis_effect_columns = get_visible_effect_columns(t)
        total_vis_columns = vis_note_columns + vis_effect_columns
      
      end
    elseif c < 1 then
      while c < 1 do
      
        --decrement the track index (with wrap-around)
        t = (t - 1) % get_track_count()
        if t == 0 then t = get_track_count() end
        
        --get the total amount of visible columns for this new track
        vis_note_columns = get_visible_note_columns(t)
        vis_effect_columns = get_visible_effect_columns(t)
        total_vis_columns = vis_note_columns + vis_effect_columns
      
        --add this track's amount of note+effect columns to our column index
        c = c + total_vis_columns
      
      end
    end
    
    --figure out if our column index is for a note column, or effect column, 
    --the unused variable will stay as nil
    if c > vis_note_columns then
      ec = c - vis_note_columns
    else
      nc = c
    end    
  end
  
  
  --FIND LINE INDEX
  if l then
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
  end
  
  return s,t,l,nc,ec
end

--FIND CORRECT INDEX---------------------------------------
local function find_correct_index(s,p,t,l,c)
    
  --find the correct sequence if our line index lies before or after the bounds of this pattern
  local _
  s,_,l = get_index(s,nil,l,nil)
  
  --get the new pattern index based on our new sequence index
  p = song.sequencer:pattern(s)
  
  --if overflow is on, then push notes out to empty columns when available
  if flags.overflow then
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
  if flags.condense then
    while true do
      if c == 1 then break
      elseif not song:pattern(p):track(t):line(l):note_column(c-1).is_empty then break
      else c = c - 1 end
    end
  end
  
  return {s = s, p = p, t = t, c = c, l = l}
end

--SET TRACK VISIBILITY------------------------------------------
local function set_track_visibility(t)
  
  if not columns_overflowed_into[t] then columns_overflowed_into[t] = 0 end
  
  local columns_to_show = math.max(columns_overflowed_into[t], originally_visible_columns[1][t])
  
  local time_changed = (time ~= 0) or (time_was_typed and typed_time ~= 1) or (offset ~= 0) or (offset_was_typed and typed_offset ~= 0) or flags.redistribute or curve_intensity[1] ~= 0
  
  song:track(t).visible_note_columns = columns_to_show  
  song:track(t).volume_column_visible = flags.vol or originally_visible_columns[2][t]
  song:track(t).panning_column_visible = flags.pan or originally_visible_columns[3][t]
  song:track(t).delay_column_visible = time_changed or originally_visible_columns[4][t]
  song:track(t).sample_effects_column_visible = flags.fx or originally_visible_columns[5][t]
  
end

--SET NOTE COLUMN VALUES----------------------------------------------
local function set_note_column_values(column,vals)

  column.note_value = vals.note_value
  column.instrument_value = vals.instrument_value
  column.volume_value = vals.volume_value
  column.panning_value = vals.panning_value
  column.delay_value = vals.delay_value
  column.effect_number_value = vals.effect_number_value
  column.effect_amount_value = vals.effect_amount_value

end

--RESTORE OLD NOTE----------------------------------------------
local function restore_old_note(counter)

  --access the ptcl values we will be indexing
  local p = selected_notes[counter].current_location.p
  local t = selected_notes[counter].current_location.t
  local c = selected_notes[counter].current_location.c
  local l = selected_notes[counter].current_location.l
  
  if selected_notes[counter].flags.clear then  --if this note's clear flag is true...
    song:pattern(p):track(t):line(l):note_column(c):clear() --clear the column clean
  
  elseif selected_notes[counter].flags.restore then  --else, if this note's restore flag is true...

    --restore the note
    set_note_column_values(
      song:pattern(p):track(t):line(l):note_column(c),
      selected_notes[counter].last_overwritten_values
    )
    
  end
      
end

--IS WILD-----------------------------------------
local function is_wild(index,counter)

  if not placed_notes[index.p] then return true end
  if not placed_notes[index.p][index.t] then return true end
  if not placed_notes[index.p][index.t][index.l] then return true end
  if not placed_notes[index.p][index.t][index.l][index.c] then 
    return true--return true if no notes were found to be storing data at this spot
  
  else return false end --return false if we found one of our notes already in this spot
  
end

--GET EXISTING NOTE----------------------------------------------
local function get_existing_note(index,counter)

  --access the column that we need to store
  local column = song:pattern(index.p):track(index.t):line(index.l):note_column(index.c)

  if column.is_empty then --if this spot is empty...
    
    selected_notes[counter].flags.write = true --set this note's write flag to true
    selected_notes[counter].flags.clear = true --set this note's clear flag to true
    selected_notes[counter].flags.restore = false  --set this note's restore flag to false
    
  else --else, if this spot is not empty...
    if is_wild(index,counter) then  --if this spot is occupied by a "wild" note...
      
      note_collisions.wild[counter] = true  --record a wild collision for this note
      
      if flags.wild_notes then --if we are overwriting wild notes with our notes...
        
        selected_notes[counter].flags.write = true --set this note's write flag to true
        selected_notes[counter].flags.clear = false --set this note's clear flag to false
        selected_notes[counter].flags.restore = true  --set this note's restore flag to true        
        
        --and store the data from the column we're overwriting
        selected_notes[counter].last_overwritten_values = {
          note_value = column.note_value,
          instrument_value = column.instrument_value,
          volume_value = column.volume_value,
          panning_value = column.panning_value,
          delay_value = column.delay_value,
          effect_number_value = column.effect_number_value,
          effect_amount_value = column.effect_amount_value
        }
        
      else  --else, if we are not overwriting wild notes with our own...
        
        selected_notes[counter].flags.write = false --set this note's write flag to false
        selected_notes[counter].flags.clear = false --set this note's clear flag to false
        selected_notes[counter].flags.restore = false  --set this note's restore flag to false 
        
      end
    
    else  --else, if it is one of our own notes...
    
      note_collisions.ours[counter] = true  --record a collision between our own notes for this note
      
      if flags.our_notes then  --if we are overwriting our own notes...
        
        selected_notes[counter].flags.write = true --set this note's write flag to true
        selected_notes[counter].flags.clear = false --set this note's clear flag to false
        selected_notes[counter].flags.restore = false  --set this note's restore flag to false
        
      else  --else, if we are not overwriting our own notes
      
        selected_notes[counter].flags.write = false --set this note's write flag to false
        selected_notes[counter].flags.clear = false --set this note's clear flag to false
        selected_notes[counter].flags.restore = false  --set this note's restore flag to false
      
      end --end: if flags.our_notes    
    end --end: if is_wild()
  end --end: column.is_empty
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

--APPLY CURVE-------------------------------------
local function apply_curve(placement,type)
  
  local anchors = {}
  if type == 1 then --if we are applying the curve for time
    if anchor_type == 1 then
      if anchor == 0 then 
        anchors[1] = 0
        anchors[2] = latest_placement - earliest_placement
      else
        anchors[1] = -(latest_placement - earliest_placement)
        anchors[2] = 0
      end
    else
      if anchor == 0 then 
        anchors[1] = 0
        anchors[2] = total_delay_range
      else 
        anchors[1] = -(total_delay_range)
        anchors[2] = 0
      end
    end
  elseif type == 2 then --if we are applying the curve for vol
    anchors[1] = flags.vol_min
    anchors[2] = flags.vol_max
  elseif type == 3 then --if we are applying the curve for pan
    anchors[1] = flags.pan_min
    anchors[2] = flags.pan_max
  elseif type == 4 then --if we are applying the curve for fx
    anchors[1] = flags.fx_min
    anchors[2] = flags.fx_max
  end
  
  --convert our placement range from (anchor1 - anchor2) to (0.0 - 1.0)
  placement = remap_range(placement,anchors[1],anchors[2],0,1)
  
  local points = {} --this will store the two points which we will interpolate between
  
  --initialize point1
  points[1] = curve_points[type].sampled[1]
  
  --find the two points
  for k,p in ipairs(curve_points[type].sampled) do --iterate through our sampled points
    if placement <= p[1] then  --if our placement is less than then xcoord of the point...
      points[2] = p  --then we have found point2...
      break --and we can break, having found both points
    end
    points[1] = p --update point1 if the current point isn't point2
  end
   
  --find where our placement sits between our two points
  placement = remap_range(
    placement,
    points[1][1],
    points[2][1],
    (type == 1 and 1 - points[1][2]) or points[1][2], --we invert if we are working with time,
    (type == 1 and 1 - points[2][2]) or points[2][2]  --because Renoise moves top-to-bottom
  )
  
  if (placement < placement - 1) then --nan check
    print("NAN!!!")
    placement = 0
  end
  
  --convert our placement back to a delay column value
  placement = math.floor(remap_range(placement,0,1,anchors[1],anchors[2]))
  
  return placement
end

--PLACE NEW NOTE----------------------------------------------
local function place_new_note(counter)

stclk(2)

  --decide which time value to use (typed or sliders)
  local time_to_use
  if time_was_typed then time_to_use = typed_time
  else time_to_use = time * time_multiplier + 1 end
  
  --decide which offset value to use (typed or sliders)
  local offset_to_use
  if offset_was_typed then offset_to_use = typed_offset * 256
  else offset_to_use = (offset * 256) * offset_multiplier end  
  
  --decide which anchor to use (where "x0.0000" would be)
  local anchor_to_use
  if anchor_type == 1 then
    if anchor == 0 then anchor_to_use = earliest_placement  
    else anchor_to_use = latest_placement end
  else
    if anchor == 0 then anchor_to_use = 0   
    else anchor_to_use = total_delay_range end
  end
  
  --decide which placement values to use
  local placement
  if flags.redistribute then --if redistribution flag is set, we use the redistributed places
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
  
  --apply our curve remapping to the note if our curve intensity is not 0
  if curve_intensity[1] ~= 0 then placement = apply_curve(placement,1) end
  
  --apply our time and offset values to our placement value
  placement = placement * time_to_use + offset_to_use
  
  --calculate the indexes where the new note will be, based on its new placement value
  local delay_difference = placement + anchor_to_use
  local new_delay_value = (delay_difference % 256)
  local line_difference = math.floor(delay_difference / 256)
  local new_line = selection.start_line + line_difference
  
  --update this note's rel_line_pos
  selected_notes[counter].rel_line_pos = new_line
  
adclk(2)
stclk(3)
  
  local index = find_correct_index(
    selected_notes[counter].original_index.s,
    selected_notes[counter].original_index.p,
    selected_notes[counter].original_index.t,
    new_line,
    selected_notes[counter].original_index.c
  )  
  
  local column = song:pattern(index.p):track(index.t):line(index.l):note_column(index.c)

adclk(3)
stclk(4)
  
  --store the note from the new spot we have moved to
  get_existing_note(index, counter)

adclk(4)
stclk(5)
  
  update_current_note_location(counter, index)

adclk(5)  
stclk(6)
  
  local vol_val = selected_notes[counter].volume_value
  if vol_val == 255 then vol_val = 128 end
  if vol_val <= 128 then 
    if flags.vol then      
      if flags.vol_re then
        vol_val = remap_range(
          counter,
          1,
          #selected_notes,
          flags.vol_min,
          flags.vol_max
        )
      else
        vol_val = remap_range(
          vol_val,
          flags.vol_orig_min,
          flags.vol_orig_max,
          flags.vol_min,
          flags.vol_max
        )
      end
      
      vol_val = apply_curve(vol_val,2)
      
    end
  end
  
  --print("vol_val: " .. vol_val)
  
  if vol_val == 128 then vol_val = 255 end
  
  local pan_val = selected_notes[counter].panning_value
  if pan_val == 255 then pan_val = 64 end
  if pan_val <= 128 then 
    if flags.pan then      
      if flags.pan_re then
        pan_val = remap_range(
          counter,
          1,
          #selected_notes,
          flags.pan_min,
          flags.pan_max
        )
      else
        pan_val = remap_range(
          pan_val,
          flags.pan_orig_min,
          flags.pan_orig_max,
          flags.pan_min,
          flags.pan_max
        )
      end
      
      pan_val = apply_curve(pan_val,3)
      
    end
  end
  
  --print("pan_val: " .. pan_val)
  
  if pan_val == 64 then pan_val = 255 end
  
  local fx_val = selected_notes[counter].effect_amount_value
  if fx_val <= 255 then 
    if flags.fx then      
      if flags.fx_re then
        fx_val = remap_range(
          counter,
          1,
          #selected_notes,
          flags.fx_min,
          flags.fx_max
        )
      else
        fx_val = remap_range(
          fx_val,
          flags.fx_orig_min,
          flags.fx_orig_max,
          flags.fx_min,
          flags.fx_max
        )
      end
      
      fx_val = apply_curve(fx_val,4)
      
    end
  end
  
  --print("fx_val: " .. fx_val)
  
  if selected_notes[counter].flags.write then
    set_note_column_values(
      column,
      {
        note_value = selected_notes[counter].note_value,
        instrument_value = selected_notes[counter].instrument_value,
        volume_value = vol_val,
        panning_value = pan_val,
        delay_value = new_delay_value,
        effect_number_value = selected_notes[counter].effect_number_value,
        effect_amount_value = fx_val
      }  
    )
  end
  
adclk(6)
  
  --add note to our placed_notes table
  add_to_placed_notes(index,counter)
  
end

--UPDATE VALUEFIELDS---------------------------------
local function update_valuefields()
  
  vb_notifiers_on = false
  
  if time_was_typed then
    vb.views.time_text.value = typed_time
  else
    vb.views.time_text.value = time * time_multiplier + 1
  end
  
  if offset_was_typed then
    vb.views.offset_text.value = typed_offset
  else
    vb.views.offset_text.value = offset * offset_multiplier
  end
  
  if debugvars.extra_curve_controls then vb.views.samplesize_text.value = curve_points[1][curve_type[1]].samplesize end
  
  vb_notifiers_on = true
  
  --print("update_valuefields() end")
  
  return true
end

--UPDATE COLLISION BITMAPS--------------------------------
local function update_collision_bitmaps()

  local our_collisions,wild_collisions = false,false
  
  for k,v in pairs(note_collisions.ours) do
    if v then our_collisions = true end
  end

  for k,v in pairs(note_collisions.wild) do
    if v then wild_collisions = true end
  end
  
  if our_collisions then our_collisions = 1 else our_collisions = 0 end
  if wild_collisions then wild_collisions = 1 else wild_collisions = 0 end

  vb.views.our_notes_collisions_bitmap.bitmap = ("Bitmaps/led%i.bmp"):format(our_collisions)
  vb.views.wild_notes_collisions_bitmap.bitmap = ("Bitmaps/led%i.bmp"):format(wild_collisions)

end

--UPDATE START POS----------------------------
local function update_start_pos()

  local earliest_note = {number = 0, line = math.huge}
  for k in ipairs(selected_notes) do
    if selected_notes[k].rel_line_pos < earliest_note.line then
      earliest_note.number = k 
      earliest_note.line = selected_notes[k].rel_line_pos
    end
  end

  start_pos.sequence = selected_notes[earliest_note.number].current_location.s
  start_pos.line = selected_notes[earliest_note.number].current_location.l
  
  return true
end

--REPOSITION CONTROLS----------------------------------------------
local function reposition_controls()

  vb_notifiers_on = false
  
  vb.views.time_slider.value = -vb.views.time_slider.value
  
  vb_notifiers_on = true

end

--SPACE KEY-----------------------------------
local function space_key()
  
  if os.clock() - last_spacebar > 0.05 then --after typing in a valuebox, space_key() double-triggers for some reason, so we need to use this timer to make sure it only triggers once per 50ms or so
    if not song.transport.playing then
      song.transport:start_at(start_pos) 
    else
      song.transport:stop()
    end
  end
  
  last_spacebar = os.clock()
  
  return true
end

--SHIFT SPACE KEY-----------------------------------
local function shift_space_key()
  
  if os.clock() - last_spacebar > 0.05 then --after typing in a valuebox, space_key() double-triggers for some reason, so we need to use this timer to make sure it only triggers once per 50ms or so
    if not song.transport.playing then
      song.transport:start_at(song.transport.edit_pos) 
    else
      song.transport:stop()
    end
  end
  
  last_spacebar = os.clock()

  return true
end

--UP KEY--------------------------------------------
local function up_key()
  
  local s,_,l = get_index(
    song.selected_sequence_index,
    1,
    song.selected_line_index - 1,
    1
  )
  
  song.selected_sequence_index = s
  song.selected_line_index = l

end

--DOWN KEY--------------------------------------------
local function down_key()

  local s,_,l = get_index(
    song.selected_sequence_index,
    1,
    song.selected_line_index + 1,
    1
  )
  
  song.selected_sequence_index = s
  song.selected_line_index = l

end

--LEFT KEY--------------------------------------------
local function left_key()

  local track = song.selected_track_index

  --find our current column index
  local column
  
  --if we do not have an effect column selected, then we have a note column selected
  if song.selected_effect_column_index == 0 then
    column = song.selected_note_column_index
  else
    column = song.selected_effect_column_index + get_visible_note_columns(track)
  end

  local s,t,l,nc,ec = get_index(
    song.selected_sequence_index,
    track,
    song.selected_line_index,
    column - 1
  )
  
  song.selected_sequence_index = s
  song.selected_track_index = t
  song.selected_line_index = l  
  if nc then song.selected_note_column_index = nc
  elseif ec then song.selected_effect_column_index = ec end

end

--RIGHT KEY--------------------------------------------
local function right_key()

  local track = song.selected_track_index
  
  --find our current column index
  local column
  
  --if we do not have an effect column selected, then we have a note column selected
  if song.selected_effect_column_index == 0 then
    column = song.selected_note_column_index
  else
    column = song.selected_effect_column_index + get_visible_note_columns(track)
  end

  local s,t,l,nc,ec = get_index(
    song.selected_sequence_index,
    track,
    song.selected_line_index,
    column + 1
  )
  
  song.selected_sequence_index = s
  song.selected_track_index = t
  song.selected_line_index = l  
  if nc then song.selected_note_column_index = nc
  elseif ec then song.selected_effect_column_index = ec end

end

--TAB KEY----------------------------------------
local function tab_key()

  local s,t,l,nc,ec = get_index(
    song.selected_sequence_index,
    song.selected_track_index + 1,
    song.selected_line_index,
    1
  )
  
  song.selected_sequence_index = s
  song.selected_track_index = t
  song.selected_line_index = l
  
  if nc then song.selected_note_column_index = nc
  elseif ec then song.selected_effect_column_index = ec end  

end

--SHIFT TAB KEY----------------------------------------
local function shift_tab_key()

  local s,t,l,nc,ec = get_index(
    song.selected_sequence_index,
    song.selected_track_index - 1,
    song.selected_line_index,
    1
  )
  
  song.selected_sequence_index = s
  song.selected_track_index = t
  song.selected_line_index = l
  
  if nc then song.selected_note_column_index = nc
  elseif ec then song.selected_effect_column_index = ec end  

end

--BINOMIAL COEFFECIENT---------------------------------
local function binom(n,k)

  if k == 0 or k == n then return 1 end
  if k < 0 or k > n then return 0 end

  if not pascals_triangle[n] then pascals_triangle[n] = {} end
  
  if not pascals_triangle[n][k] then
  
    pascals_triangle[n][k] = binom(n-1,k-1) + binom(n-1,k)    
    
  end
  
  return pascals_triangle[n][k]
end

--BERNSTEIN BASIS POLYNOMIAL---------------------------
local function bern(val,v,n)

  return binom(n,v) * (val^v) * (1 - val)^(n-v)  
end

--SIGN------------------------------------
local function sign(number)

  return number > 0 and 1 or (number == 0 and 0 or -1)  
end

--GET CURVE--------------------------------------
local function get_curve(t,points)
  
  local coords = {}  
  local numerators,denominators = {0,0},{0,0} --{x,y numerators}, {x,y denominators}
  local n = #points
  
  for j = 1, 2 do --run j loop once for x coords, once for y coords
    for i,point in ipairs(points)do --sum all of the points up with bernstein blending
      
      numerators[j] = numerators[j] + ( bern(t,i-1,n-1) * point[j] * point[3] )
      denominators[j] = denominators[j] + ( bern(t,i-1,n-1) * point[3] )
      
    end    
    coords[j] = numerators[j]/denominators[j]    
  end
  
  return coords
end

--INIT BUFFERS----------------------------
local function init_buffers(i)

  for x = 1, curve_displays[i].xsize do
    if not curve_displays[i].buffer1[x] then curve_displays[i].buffer1[x] = {} end
    if not curve_displays[i].buffer2[x] then curve_displays[i].buffer2[x] = {} end
    for y = 1, curve_displays[i].ysize do
      curve_displays[i].buffer1[x][y] = 0
      curve_displays[i].buffer2[x][y] = 0
    end
  end
end

--CALCULATE CURVE---------------------------------
local function calculate_curve(i)
  
  table.clear(curve_points[i].sampled)
  
  local points 
  if curve_intensity[i] > 0 then
    points = curve_points[i][curve_type[i]].positive
  elseif curve_intensity[i] < 0 then
    points = curve_points[i][curve_type[i]].negative
  else
    points = curve_points[i].default.points
  end
  
  local intensity = math.abs(curve_intensity[i])
  
  local samplesize = curve_points[i][curve_type[i]].samplesize
  if curve_intensity[i] ~= 0 then
    samplesize = curve_points[i][curve_type[i]].samplesize
  else
    samplesize = curve_points[i].default.samplesize
  end
  
  --find the x,y coords for each samplesize'd-increment of t along our curve
  for x = 1, samplesize do
    
    --get our t value
    local t = (x-1) / (samplesize-1)
    
    local coords = get_curve(t,points)
    local linear = get_curve(t, curve_points[i].default.points)
    
    --interpolate between our curve, and a linear distribution, based on curve intensity
    coords[1] = intensity * coords[1] + (1 - intensity) * linear[1]
    coords[2] = intensity * coords[2] + (1 - intensity) * linear[2]
    
    curve_points[i].sampled[x] = {coords[1],coords[2]}    
  
  end

end

--RASTERIZE CURVE-------------------------------------------
local function rasterize_curve(i)

  --store our buffer from last frame
  curve_displays[i].buffer2 = table.rcopy(curve_displays[i].buffer1)
  
  --clear buffer1 to all 0's
  for x = 1, curve_displays[i].xsize do
    for y = 1, curve_displays[i].ysize do
      curve_displays[i].buffer1[x][y] = 0
    end
  end

  if drawmode == "point" then
  
    for p = 1, #curve_points[i].sampled do
    
      local coords = {curve_points[i].sampled[p][1],curve_points[i].sampled[p][2]}
      
      --convert from float in 0-1 range to integer in 1-curve_displays.xsize range
      coords[1] = math.floor(coords[1] * (curve_displays[i].xsize-1) + 1.5)
      
      --convert from float in 0-1 range to integer in 1-curve_displays.ysize range
      coords[2] = math.floor(coords[2] * (curve_displays[i].ysize-1) + 1.5)
      
      if not (coords[1] < coords[1] - 1 and coords[2] < coords[2] - 1) then --nan check
        --add this pixel into our buffer
        curve_displays[i].buffer1[coords[1]][coords[2]] = 1
      end
      
    end
  
  else

    for p = 1, #curve_points[i].sampled - 1 do
      
      local point_a, point_b, pixel_a, pixel_b = 
        { curve_points[i].sampled[p][1], curve_points[i].sampled[p][2] },
        { curve_points[i].sampled[p+1][1], curve_points[i].sampled[p+1][2] },
        {},
        {}
        
        
      --convert point_a from float in 0-1 range to float in 1-curve_displays.xsize range
      point_a[1] = remap_range(point_a[1],0,1,1,curve_displays[i].xsize)
      point_a[2] = remap_range(point_a[2],0,1,1,curve_displays[i].ysize)
      
      --convert point_b from float in 0-1 range to float in 1-curve_displays.xsize range
      point_b[1] = remap_range(point_b[1],0,1,1,curve_displays[i].xsize)
      point_b[2] = remap_range(point_b[2],0,1,1,curve_displays[i].ysize)
        
      --local floatslope = (point_b[2] - point_a[2]) / (point_b[1] - point_a[1]) --y/x
          
      --convert point_a from float to integer (pixel)
      pixel_a[1] = math.floor(point_a[1] + 0.5)
      pixel_a[2] = math.floor(point_a[2] + 0.5)
      
      --convert point_b from float to integer (pixel)
      pixel_b[1] = math.floor(point_b[1] + 0.5)
      pixel_b[2] = math.floor(point_b[2] + 0.5)
      
      --calculate the difference in our x and y coords from point b to point a
      local diff = { pixel_b[1]-pixel_a[1] , pixel_b[2]-pixel_a[2] }
      
      --find out which plane we will traverse by 1 pixel each loop iteration
      local plane
      if math.abs(diff[1]) >= math.abs(diff[2]) then
        --we want to traverse the x-plane
        plane = 1
      else
        --we want to traverse the y-plane
        plane = 2
      end
      
      --determine if we will be moving in positive or negative direction along plane
      local step = sign(diff[plane])
      
      --calculate our slope
      local slope = step * ((plane == 1 and diff[2]/diff[1]) or diff[1]/diff[2]) --(our slope is dependent on which plane we're on)
      
      local current_coords = {pixel_a[1],pixel_a[2]}
      local slope_acc = point_a[plane%2 + 1] - pixel_a[plane%2 + 1]
      while(true) do
        
        curve_displays[i].buffer1[current_coords[1]][current_coords[2]] = 1
        
        if current_coords[plane] == pixel_b[plane] then break end --if we are at the end pixel, we break
        
        current_coords[plane] = current_coords[plane] + step
        slope_acc = slope_acc + slope
        current_coords[plane%2 + 1] = math.floor(pixel_a[plane%2 + 1] + slope_acc + 0.5)
      
      end      
    end    
  end

end

--UPDATE CURVE GRID-------------------------------
local function update_curve_grid(i)
  
  --draw our curve
  for x,column in ipairs(curve_displays[i].display) do
    for y,pixel in ipairs(column) do      
      if curve_displays[i].buffer1[x][y] ~= curve_displays[i].buffer2[x][y] then
      
        pixel.bitmap = ("Bitmaps/%s.bmp"):format(curve_displays[i].buffer1[x][y])
        
      end      
    end
  end

end


--UPDATE CURVE DISPLAY-------------------------------
local function update_curve_display(i)

  if not curve_displays[i].buffer1[1] then init_buffers(i) end  --inits the buffers if needed
  
  calculate_curve(i) --samples points on the curve and stores them
  
  rasterize_curve(i) --interpolates sampled points, adding them to the pixel buffer
          
  update_curve_grid(i) --pushes the pixel buffer to the display

  return true
end


--UPDATE ALL CURVE DISPLAYS-----------------------------
local function update_all_curve_displays()

  for i = 1, 4 do    
    update_curve_display(i)
  end

  return true
end

--APPLY REFORM------------------------------------------
local function apply_reform()

rstclk(0)
stclk(0)
  
  --set the clock we will use to determine if idle processing will be necessary next time
  previous_time = os.clock()

  --print("apply_reform()")
  
  if not valid_selection then
    app:show_error("There is no valid selection to operate on!")
    deactivate_controls()
    return false
  end
  
  table.clear(columns_overflowed_into)
  table.clear(note_collisions.ours)
  table.clear(note_collisions.wild)
  
  --restore everything to how it was, so we don't run into our own notes during calculations
  for k in ipairs(selected_notes) do
    restore_old_note(k)
  end
  
  --clear our "placed_notes" table so we can lay them down one by one cleanly
  table.clear(placed_notes)

for i = 1, 9 do
rstclk(i)
end
stclk(1)
  
  --place our notes into place one by one
  for k in ipairs(selected_notes) do
    place_new_note(k)
  end

--rdclk(2,"clock2: ")
--rdclk(3,"find_correct_index clock: ")
--rdclk(4,"get_existing_note clock: ")
--rdclk(5,"update_current_note_location clock: ")
--rdclk(6,"set_note_column_values clock: ")
--rdclk(7,"is_wild clock: ") --removed
--rdclk(8,"storing notes clock: ")

adclk(1)
--rdclk(1,"place_new_note total clock: ")
  
  --show vol,pan,dly,fx columns and note columns...
  --for first track
  if is_note_track[selection.start_track] then 
    set_track_visibility(selection.start_track)
  end
  
  --for all middle tracks
  if selection.end_track - selection.start_track > 1 then
    for t = selection.start_track + 1, selection.end_track - 1 do 
      if is_note_track[t] then   
        set_track_visibility(t)
      end
    end
  end  
  
  --and for the last track
  if is_note_track[selection.end_track] then
    set_track_visibility(selection.end_track)
  end
  
  --update our valuefield texts
  update_valuefields()
  
  --update our collision indicator bitmaps
  update_collision_bitmaps()
  
  --update our start position for spacebar playback
  update_start_pos()
  
  --record the time it took to process everything
  previous_time = os.clock() - previous_time
  
adclk(0)
rdclk(0,"apply_reform() total clock: ")
  
end

--if performance becomes a problem, we use add_reform_idle_notifier() instead of apply_reform()
--APPLY REFORM NOTIFIER----------------------------------
local function apply_reform_notifier()
    
  apply_reform()
  
  tool.app_idle_observable:remove_notifier(apply_reform_notifier)
  
  if debugvars.print_notifier_trigger then print("idle notifier triggered!") end
end

--ADD REFORM IDLE NOTIFIER--------------------------------------
local function add_reform_idle_notifier()
  
  
  if not tool.app_idle_observable:has_notifier(apply_reform_notifier) then
    tool.app_idle_observable:add_notifier(apply_reform_notifier)
  
    if debugvars.print_notifier_attach then print("idle notifier attached!") end
  end

end

--QUEUE PROCESSING--------------------------------------
local function queue_processing()

  if debugvars.print_queue_processing then
    print("queue_processing()")
  end

  if not idle_processing then
    apply_reform()
  else
    add_reform_idle_notifier()
  end
  
  --if apply_reform() took longer than 40ms, we will move processing to idle notifier next time
  if previous_time < 0.04 then
    idle_processing = false
  else
    idle_processing = true
  end

end

--GET THEME DATA--------------------------------
local function get_theme_data()

  app:save_theme("Theme.xrnc")

  --open/cache the file contents as a string
  local themefile = io.open("Theme.xrnc")
  local themestring = themefile:read("*a")
  themefile:close()
  
  --find the indices where the Selected_Button_Back property begins and ends
  local i = {}
  i[1], i[2] = themestring:find("<Selected_Button_Back>",0,true)
  i[3], i[4] = themestring:find("</Selected_Button_Back>",0,true)
  
  local stringtemp = themestring:sub(i[2]+1,i[3]-1)
  
  i[1], i[2] = stringtemp:find(",",0,true)
  
  theme.selected_button_back[1] = tonumber(stringtemp:sub(0,i[1]-1))
  
  i[2], i[3] = stringtemp:find(",",i[2]+1,true)
  
  theme.selected_button_back[2] = tonumber(stringtemp:sub(i[1]+1,i[2]-1))
  
  theme.selected_button_back[3] = tonumber(stringtemp:sub(i[2]+1,stringtemp:len()))

  return true
end

--SET THEME COLORS-----------------------------------------
local function set_theme_colors()

  if flags.vol_re then vb.views.vol_re_button.color = theme.selected_button_back end

end

--SHOW WINDOW---------------------------------------------------- 
local function show_window()

  --prepare the window content if it hasn't been done yet
  if not window_content then  
    
    --set our default sizes/margins and such
    local sliders_width = 22
    local sliders_height = 110
    local multipliers_size = 24
    local default_margin = 2
    local default_gap = 5
    local re_sliders_width = 20
    local re_sliders_height = 90
    local rack_styles = {
      "invisible", -- no background
      "plain", -- undecorated, single coloured background
      "border", -- same as plain, but with a bold nested border
      "body", -- main "background" style, as used in dialog backgrounds
      "panel", -- alternative "background" style, beveled
      "group", -- background for "nested" groups within body
    }
    local main_rack_style = rack_styles[5]
    local re_rack_style = rack_styles[6]
    local bitmap_modes = {
      "plain", -- bitmap is drawn as is, no recoloring is done
      "transparent", -- same as plain, but black pixels will be fully transparent
      "button_color", -- recolor the bitmap, using the theme's button color
      "body_color", -- same as 'button_back' but with body text/back color
      "main_color", -- same as 'button_back' but with main text/back colors
    }
    local border_bmp_mode = bitmap_modes[4]
    
    --create the curve displays
    local curvedisplayrow = {}
    for i = 1, 4 do
      curvedisplayrow[i] = vb:row {}
      --populate the display
      for x = 1, curve_displays[i].xsize do       
        curve_displays[i].display[x] = {}
        local column = vb:column {}
        for y = 1, curve_displays[i].ysize do
          --fill the column with pixels
          curve_displays[i].display[x][curve_displays[i].ysize+1 - y] = vb:bitmap {
            bitmap = "Bitmaps/0.bmp",
            mode = "body_color"
          }
          --add each pixel by "hand" into the column from bottom to top
          column:add_child(curve_displays[i].display[x][curve_displays[i].ysize+1 - y])
        end
        --add the column into the row from left to right
        curvedisplayrow[i]:add_child(column)
      end
    end
    
    
    window_content = vb:column {  --our entire view will be in one big column
      id = "window_content",
      --width = 144,  --set the window's width
      
      vb:row {  --main row
        id = "window_row",
      
        vb:column { --contains time/curve/offset columns
                
          vb:horizontal_aligner { --aligns time/curve/offset control groups to window width
            mode = "distribute",
            margin = default_margin,
          
            vb:column { --contains all time-related controls
              style = main_rack_style,
              --margin = default_margin,
              
              vb:space {
                height = default_gap
              },
              
              vb:horizontal_aligner { --aligns icon in column
                mode = "justify",
                
                --[[vb:vertical_aligner {
                  mode = "top",
                  vb:bitmap{bitmap = "Bitmaps/tl.bmp", mode = border_bmp_mode}
                },--]]
                
                vb:column {                
                  --vb:space{height = default_margin},
                
                  vb:bitmap { --icon at top of time controls
                    bitmap = "Bitmaps/clock.bmp",
                    mode = "body_color"
                  }
                },
                
                --[[vb:vertical_aligner {
                  mode = "top",
                  vb:bitmap {bitmap = "Bitmaps/tr.bmp", mode = border_bmp_mode}
                },--]]
                
              },
              
              vb:horizontal_aligner { --aligns time valuefield in column
                mode = "center",
                
                vb:valuefield {
                  id = "time_text",
                  tooltip = "Type exact time multiplication values here!",
                  align = "center",
                  min = -256,
                  max = 256,
                  value = time,
                  
                  --tonumber converts any typed-in user input to a number value 
                  --(called only if value was typed)
                  tonumber = function(str)
                    local val = str:gsub("[^0-9.-]", "") --filter string to get numbers and decimals
                    val = tonumber(val) --this tonumber() is Lua's basic string-to-number converter
                    if val and -256 <= val and val <= 256 then --if val is a number, and within min/max
                      if debugvars.print_valuefield then print("time tonumber = " .. val) end
                      typed_time = val
                      time_was_typed = true                     
                      queue_processing()
                    end
                    return val
                  end,
                  
                  --tostring is called when field is clicked, 
                  --after tonumber is called,
                  --and after the notifier is called
                  --it converts the value to a formatted string to be displayed
                  tostring = function(value)
                    if debugvars.print_valuefield then print(("time tostring = x%.3f"):format(value)) end
                    return ("x%.3f"):format(value)
                  end,        
                  
                  --notifier is called whenever the value is changed
                  notifier = function(value)
                  if debugvars.print_valuefield then print("time_text notifier") end
                  end
                }
              },
              
              vb:horizontal_aligner { --aligns time slider in column
                mode = "center",
                            
                vb:minislider {    
                  id = "time_slider", 
                  tooltip = "Time", 
                  min = -1, 
                  max = 1, 
                  value = time-1, 
                  width = sliders_width, 
                  height = sliders_height, 
                  notifier = function(value)
                  if vb_notifiers_on then
                      if anchor == 0 then
                        time = -value
                      else
                        time = value
                      end              
                      time_was_typed = false
                      queue_processing() 
                    end
                  end    
                }
              },
                
              vb:horizontal_aligner { --aligns time rotary in column
                mode = "justify",
                  
                --[[vb:vertical_aligner {
                  mode = "bottom",
                  vb:bitmap {bitmap = "Bitmaps/bl.bmp", mode = border_bmp_mode}
                },  --]] 
                
                vb:rotary { 
                  id = "time_multiplier_rotary", 
                  tooltip = "Time Slider Range Extension", 
                  min = 1, 
                  max = 63, 
                  value = time_multiplier, 
                  width = multipliers_size, 
                  height = multipliers_size, 
                  notifier = function(value)              
                    if vb_notifiers_on then
                      time_multiplier = value
                      time_was_typed = false
                      queue_processing()
                    end
                  end 
                }, --close rotary 
                
                --[[vb:vertical_aligner {
                  mode = "bottom",
                  vb:bitmap {bitmap = "Bitmaps/br.bmp", mode = border_bmp_mode}
                }--]]
                        
              }, --close horizontal rotary aligner
              
              vb:space {
                height = default_gap
              }
              
            }, --close time controls column
            
            
            vb:column { --contains all curve-related controls
              id = "curve_column",
              style = main_rack_style,
              --margin = default_margin,
              
              vb:space {
                height = default_gap
              },
              
              --vb:space{height = default_margin},
              
              vb:horizontal_aligner { --aligns curve display in column
                mode = "justify",
                --spacing = -22,
                
                --[[vb:vertical_aligner {
                  mode = "top",
                  vb:bitmap{bitmap = "Bitmaps/tl.bmp", mode = border_bmp_mode}
                },--]]
                
                --vb:column{
                  --margin = 3,
                  curvedisplayrow[1],
                --},
                
                --[[vb:bitmap {
                  bitmap = "Bitmaps/curvebutton.bmp",
                  mode = "body_color",
                  notifier = function()
                    curve_type[1] = curve_type[1] % 2 + 1
                    update_curve_display(1)
                    queue_processing()
                  end
                }--]]
                
                --[[vb:vertical_aligner {
                  mode = "top",
                  vb:bitmap{bitmap = "Bitmaps/tr.bmp", mode = border_bmp_mode}
                },--]]
                
              },
              
              vb:horizontal_aligner { --aligns time valuefield in column
                mode = "center",
                
                vb:valuefield {
                  id = "curve_text",
                  tooltip = "Type exact curve intensity values here!",
                  align = "center",
                  min = -1,
                  max = 1,
                  value = 0,
                  
                  --tonumber converts any typed-in user input to a number value 
                  --(called only if value was typed)
                  tonumber = function(str)
                    local val = str:gsub("[^0-9.-]", "") --filter string to get numbers and decimals
                    val = tonumber(val) --this tonumber() is Lua's basic string-to-number converter
                    if val and -1 <= val and val <= 1 then --if val is a number, and within min/max
                      curve_intensity[1] = val
                      vb.views.curve_slider.value = val
                      update_curve_display(1)
                      queue_processing()
                    end
                    return val
                  end,
                  
                  --tostring is called when field is clicked, 
                  --after tonumber is called,
                  --and after the notifier is called
                  --it converts the value to a formatted string to be displayed
                  tostring = function(value)
                    return ("x%.2f"):format(value)
                  end,        
                  
                  --notifier is called whenever the value is changed
                  notifier = function(value)
                  end
                }
              },
              
              vb:horizontal_aligner { --aligns curve slider in column
                mode = "center",
                            
                vb:minislider {    
                  id = "curve_slider", 
                  tooltip = "Curve", 
                  min = -1, 
                  max = 1, 
                  value = curve_intensity[1], 
                  width = sliders_width, 
                  height = sliders_height, 
                  notifier = function(value)
                    if vb_notifiers_on then
                      curve_intensity[1] = value
                      vb.views.curve_text.value = value
                      update_curve_display(1)
                      queue_processing()
                    end
                  end    
                }          
              },
              
              vb:horizontal_aligner {
                mode = "justify",
              
                --[[vb:vertical_aligner {
                  mode = "bottom",
                  vb:space{height = 20},
                  vb:bitmap{bitmap = "Bitmaps/bl.bmp", mode = border_bmp_mode}
                },--]]
                
                vb:vertical_aligner {
                  mode = "top",
                  
                  vb:row {                
                    vb:bitmap {
                      id = "curve_type_1",
                      bitmap = "Bitmaps/curve1pressed.bmp",
                      mode = "button_color",
                      notifier = function()
                        vb.views.curve_type_1.bitmap = "Bitmaps/curve1pressed.bmp"
                        vb.views.curve_type_2.bitmap = "Bitmaps/curve2.bmp"
                        curve_type[1] = 1
                        update_curve_display(1)
                        queue_processing()
                      end
                    },
                    vb:bitmap {
                      id = "curve_type_2",
                      bitmap = "Bitmaps/curve2.bmp",
                      mode = "button_color",
                      notifier = function()
                        vb.views.curve_type_1.bitmap = "Bitmaps/curve1.bmp"
                        vb.views.curve_type_2.bitmap = "Bitmaps/curve2pressed.bmp"
                        curve_type[1] = 2
                        update_curve_display(1)
                        queue_processing()
                      end
                    },
                    
                    vb:space {
                      height = 24,
                    }
                                        
                  },  --close row
                  
                  vb:space {
                    height = default_gap
                  }
                  
                },  --close vertical aligner
                                  
                --[[vb:vertical_aligner {
                  mode = "bottom",
                  vb:space{height = 20},
                  vb:bitmap{bitmap = "Bitmaps/br.bmp", mode = border_bmp_mode}
                }--]]
                  
              } --close horizontal aligner
            }, --close curve controls column
          
        
            vb:column { --contains all offset-related controls
              style = main_rack_style,
              --margin = default_margin,
              
              vb:space {
                height = default_gap
              },
              
              --vb:space{height = default_margin},
            
              vb:horizontal_aligner { --aligns icon in column
                mode = "justify",
                
                --[[vb:vertical_aligner {
                  mode = "top",
                  vb:bitmap{bitmap = "Bitmaps/tl.bmp", mode = border_bmp_mode}
                },--]]
                
                vb:bitmap { --icon at top of offset controls
                  bitmap = "Bitmaps/arrows.bmp",
                  mode = "body_color"
                },
                
                --[[vb:vertical_aligner {
                  mode = "top",
                  vb:bitmap{bitmap = "Bitmaps/tr.bmp", mode = border_bmp_mode}
                }--]]
              },
            
              vb:horizontal_aligner { --aligns offset valuefield in column
                mode = "center",
                
                vb:valuefield {
                  id = "offset_text",
                  tooltip = "Type exact line offset values here!",
                  align = "center",
                  min = -256,
                  max = 256,
                  value = 0,
                  
                  --called when a value is typed in, to convert the input string to a number value
                  tonumber = function(str)
                    local val = str:gsub("[^0-9.-]", "") --filter string to get numbers and decimals
                    val = tonumber(val) --this tonumber() is Lua's basic string-to-number converter
                    if val and -256 <= val and val <= 256 then --if val is a number, and within min/max
                      if debugvars.print_valuefield then print("offset tonumber = " .. val) end
                      typed_offset = val
                      offset_was_typed = true
                      queue_processing()
                    end
                    return val
                  end,
                  
                  --called when field is clicked, after tonumber is called, and after the notifier is called
                  --it converts the value to a formatted string to be displayed
                  tostring = function(value)
                    if debugvars.print_valuefield then print(("offset tostring = %.1f lines"):format(value)) end
                    if value == 0 then return "0.0 lines" end           
                    return ("%.1f lines"):format(value)
                  end,
                  
                  --called whenever the value is changed
                  notifier = function(value)
                  if debugvars.print_valuefield then print("offset_text notifier") end
                  end
                }
              },
              
              vb:horizontal_aligner { --aligns offset slider in column
                mode = "center",
              
                vb:minislider {    
                  id = "offset_slider", 
                  tooltip = "Offset", 
                  min = -1, 
                  max = 1, 
                  value = 0, 
                  width = sliders_width, 
                  height = sliders_height, 
                  notifier = function(value)            
                    if vb_notifiers_on then
                      offset_was_typed = false
                      offset = -value
                      queue_processing()
                    end
                  end    
                }
              },
              
              vb:horizontal_aligner { --aligns offset rotary in column
                mode = "justify",
              
                --[[vb:vertical_aligner {
                  mode = "bottom",
                  vb:bitmap{bitmap = "Bitmaps/bl.bmp", mode = border_bmp_mode}
                },--]]
              
                vb:rotary { 
                  id = "offset_multiplier_rotary", 
                  tooltip = "Offset Slider Range Extension", 
                  min = 1, 
                  max = 63, 
                  value = 1, 
                  width = multipliers_size, 
                  height = multipliers_size, 
                  notifier = function(value)              
                    if vb_notifiers_on then
                      offset_was_typed = false
                      offset_multiplier = value
                      queue_processing()
                    end
                  end 
                }, --close rotary
                
                --[[vb:vertical_aligner {
                  mode = "bottom",
                  vb:bitmap{bitmap = "Bitmaps/br.bmp", mode = border_bmp_mode}
                }--]]
                
              }, --close rotary aligner
              
              vb:space {
                height = default_gap
              }
              
            } --close offset column
          } --close time/curve/offset aligner
        }, --close time/curve/offset column
        
        vb:column {
          vb:horizontal_aligner {
            mode = "center",
            --margin = default_margin,
            
            vb:bitmap {
              tooltip = "Indicates if any notes currently being processed are colliding with other processed notes",
              id = "our_notes_collisions_bitmap",
              mode = "main_color",
              bitmap = "Bitmaps/led0.bmp"
            },
            
            vb:bitmap {
              tooltip = "Indicates if any notes currently being processed are colliding with non-processed notes",
              id = "wild_notes_collisions_bitmap",
              mode = "main_color",
              bitmap = "Bitmaps/led0.bmp"
            }      
          },
          
          vb:button { --help button
            tooltip = "Help",
            bitmap = "Bitmaps/question.bmp",
            --width = "100%",
            notifier = function()
              app:open_url("https://xephyrpanda.wixsite.com/citrus64/reform")
            end
          }
          
        },
        
        vb:column { --contains vol,pan,fx buttons
          --margin = default_margin,
          
          vb:vertical_aligner {
            mode = "top",
            spacing = 2,
          
            vb:bitmap {
              id = "volbutton",
              tooltip = "Volume Remapping",
              bitmap = "Bitmaps/volbutton.bmp",
              mode = "button_color",
              notifier = function()
                flags.vol = not flags.vol
                vb.views.vol_column.visible = flags.vol
                if flags.vol then vb.views.volbutton.bitmap = "Bitmaps/volbuttonpressed.bmp"
                else vb.views.volbutton.bitmap = "Bitmaps/volbutton.bmp" end
                queue_processing()
              end
            },
            
            vb:bitmap {
              id = "panbutton",
              tooltip = "Panning Remapping",
              bitmap = "Bitmaps/panbutton.bmp",
              mode = "button_color",
              notifier = function()
                flags.pan = not flags.pan
                vb.views.pan_column.visible = flags.pan
                if flags.pan then vb.views.panbutton.bitmap = "Bitmaps/panbuttonpressed.bmp"
                else vb.views.panbutton.bitmap = "Bitmaps/panbutton.bmp" end
                queue_processing()
              end
            },
            
            vb:bitmap {
              id = "fxbutton",
              tooltip = "FX Value Remapping",
              bitmap = "Bitmaps/fxbutton.bmp",
              mode = "button_color",
              notifier = function()
                flags.fx = not flags.fx
                vb.views.fx_column.visible = flags.fx
                if flags.fx then vb.views.fxbutton.bitmap = "Bitmaps/fxbuttonpressed.bmp"
                else vb.views.fxbutton.bitmap = "Bitmaps/fxbutton.bmp" end
                queue_processing()
              end
            }
            
          }
        },
        
        vb:column { --contains all volume-related controls
          id = "vol_column",
          style = re_rack_style,
          --margin = default_margin,
          visible = false,
          
          vb:space{height = default_margin},
          
          vb:horizontal_aligner { --aligns icon in column
            mode = "center",
            
            vb:bitmap { --icon at top of controls
              bitmap = "Bitmaps/vol.bmp",
              mode = "body_color"
            }
          },
          
          vb:space{height = default_margin},
          
          vb:valuebox {
            id = "vol_max_box",
            tooltip = "Volume Hi",
            width = 50,
            height = 15,
            min = 0,
            max = 128,
            value = 128,
            
            --called when a value is typed in, to convert the input string to a number value
            tonumber = function(str)
              return tonumber(str, 0x10)
            end,
            
            --called when field is clicked, after tonumber is called, and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(val)
              return ("%.2X"):format(val)
            end,
            
            --called whenever the value is changed
            notifier = function(val)
              if vb_notifiers_on then
                flags.vol_max = (val < 255 and val) or 255
                queue_processing()
              end
            end          
          }, --close volume valuebox
          
          vb:space{height = default_margin},
          
          vb:horizontal_aligner {
            mode = "distribute",
          
            vb:column {
            
              vb:horizontal_aligner {
                mode = "center",
                
                curvedisplayrow[2]
              },
            
              vb:horizontal_aligner { --aligns slider in column
                mode = "center",
              
                vb:minislider {    
                  id = "volume_slider", 
                  tooltip = "Volume Curve", 
                  min = -1, 
                  max = 1, 
                  value = curve_intensity[2], 
                  width = re_sliders_width, 
                  height = re_sliders_height, 
                  notifier = function(value)            
                    if vb_notifiers_on then
                      curve_intensity[2] = value
                      update_curve_display(2)
                      queue_processing()
                    end
                  end    
                }
              }
            }
          },
          
          vb:valuebox {
            id = "vol_min_box",
            tooltip = "Volume Lo",
            width = 50,
            height = 15,
            min = 0,
            max = 128,
            value = 0,
            
            --called when a value is typed in, to convert the input string to a number value
            tonumber = function(str)
              return tonumber(str, 0x10)
            end,
            
            --called when field is clicked, after tonumber is called, and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(val)
              return ("%.2X"):format(val)
            end,        
            
            --called whenever the value is changed
            notifier = function(val)
              if vb_notifiers_on then
                flags.vol_min = (val < 255 and val) or 255
                queue_processing()
              end
            end
          
          },
          
          vb:horizontal_aligner { --aligns in column
            mode = "center",
            
            vb:button { --redistribute button
              id = "vol_re_button",
              tooltip = "Redistribute Volume evenly Throughout Selection\n(based on Volume Lo and Volume Hi values)",
              bitmap = "Bitmaps/redistributelvls.bmp",
              width = "100%",
              notifier = function()
                flags.vol_re = not flags.vol_re
                if flags.vol_re then
                  vb.views.vol_re_button.color = theme.selected_button_back
                else 
                  vb.views.vol_re_button.color = {0,0,0}
                end
                queue_processing()
              end
            }
          }          
        }, --close volume controls column
        
        vb:column { --contains all panning-related controls
          id = "pan_column",
          style = re_rack_style,
          --margin = default_margin,
          visible = false,
          
          vb:space{height = default_margin},
          
          vb:horizontal_aligner { --aligns icon in column
            mode = "center",
            
            vb:bitmap { --icon at top of controls
              bitmap = "Bitmaps/pan.bmp",
              mode = "body_color"
            }
          },
          
          vb:space{height = default_margin},
          
          vb:valuebox {
            id = "pan_max_box",
            tooltip = "Panning Hi",
            width = 50,
            height = 15,
            min = 0,
            max = 128,
            value = 128,
            
            --called when a value is typed in, to convert the input string to a number value
            tonumber = function(str)
              return tonumber(str, 0x10)
            end,
            
            --called when field is clicked, after tonumber is called, and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(val)
              return ("%.2X"):format(val)
            end,
            
            --called whenever the value is changed
            notifier = function(val)
              if vb_notifiers_on then
                flags.pan_max = (val < 255 and val) or 255
                queue_processing()
              end
            end          
          }, --close pan valuebox
          
          vb:space{height = default_margin},
          
          vb:horizontal_aligner {
            mode = "distribute",
          
            vb:column { --contains panning remapping controls
            
              vb:horizontal_aligner {
                mode = "center",
                
                curvedisplayrow[3]
              },
              
              vb:horizontal_aligner { --aligns slider in column
                mode = "center",
              
                vb:minislider {    
                  id = "panning_slider", 
                  tooltip = "Panning Curve", 
                  min = -1, 
                  max = 1, 
                  value = curve_intensity[3], 
                  width = re_sliders_width, 
                  height = re_sliders_height, 
                  notifier = function(value)            
                    if vb_notifiers_on then
                      curve_intensity[3] = value
                      update_curve_display(3)
                      queue_processing()
                    end
                  end    
                }
              }
            }
          },  --close horizontal aligner
            
          vb:valuebox {
            id = "pan_min_box",
            tooltip = "Panning Lo",
            width = 50,
            height = 15,
            min = 0,
            max = 128,
            value = 0,
            
            --called when a value is typed in, to convert the input string to a number value
            tonumber = function(str)
              return tonumber(str, 0x10)
            end,
            
            --called when field is clicked, after tonumber is called, and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(val)
              return ("%.2X"):format(val)
            end,        
            
            --called whenever the value is changed
            notifier = function(val)
              if vb_notifiers_on then
                flags.pan_min = (val < 255 and val) or 255
                queue_processing()
              end
            end
          
          },
          
          vb:horizontal_aligner { --aligns in column
            mode = "center",
            
            vb:button { --redistribute button
              id = "pan_re_button",
              tooltip = "Redistribute Panning evenly throughout selection\n(based on Panning Lo and Panning Hi values)",
              bitmap = "Bitmaps/redistributelvls.bmp",
              width = "100%",
              notifier = function()
                flags.pan_re = not flags.pan_re
                if flags.pan_re then
                  vb.views.pan_re_button.color = theme.selected_button_back
                else 
                  vb.views.pan_re_button.color = {0,0,0}
                end
                queue_processing()
              end
            }
          }          
        }, --close panning controls column       
        
        vb:column { --contains all fx-related controls
          id = "fx_column",
          style = re_rack_style,
          --margin = default_margin,
          visible = false,
          
          vb:space{height = default_margin},
          
          vb:horizontal_aligner { --aligns icon in column
            mode = "center",
            
            vb:bitmap { --icon at top of controls
              bitmap = "Bitmaps/fx.bmp",
              mode = "body_color"
            }
          },
          
          vb:space{height = default_margin},
          
          vb:valuebox {
            id = "fx_max_box",
            tooltip = "FX Hi",
            width = 50,
            height = 15,
            min = 0,
            max = 255,
            value = 255,
            
            --called when a value is typed in, to convert the input string to a number value
            tonumber = function(str)
              return tonumber(str, 0x10)
            end,
            
            --called when field is clicked, after tonumber is called, and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(val)
              return ("%.2X"):format(val)
            end,
            
            --called whenever the value is changed
            notifier = function(val)
              if vb_notifiers_on then
                flags.fx_max = (val <= 255 and val) or 255
                queue_processing()
              end
            end          
          }, --close fx valuebox
          
          vb:space{height = default_margin},
          
          vb:horizontal_aligner {
            mode = "distribute",
          
            vb:column { --contains FX remapping controls
            
              vb:horizontal_aligner {
                mode = "center",
                
                curvedisplayrow[4]
              },
              
              vb:horizontal_aligner { --aligns slider in column
                mode = "center",
              
                vb:minislider {    
                  id = "FX_slider", 
                  tooltip = "FX Curve", 
                  min = -1, 
                  max = 1, 
                  value = curve_intensity[3], 
                  width = re_sliders_width, 
                  height = re_sliders_height, 
                  notifier = function(value)            
                    if vb_notifiers_on then
                      curve_intensity[4] = value
                      update_curve_display(4)
                      queue_processing()
                    end
                  end    
                }
              }
            }
          },  --close horizontal aligner
            
          vb:valuebox {
            id = "fx_min_box",
            tooltip = "FX Lo",
            width = 50,
            height = 15,
            min = 0,
            max = 255,
            value = 0,
            
            --called when a value is typed in, to convert the input string to a number value
            tonumber = function(str)
              return tonumber(str, 0x10)
            end,
            
            --called when field is clicked, after tonumber is called, and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(val)
              return ("%.2X"):format(val)
            end,        
            
            --called whenever the value is changed
            notifier = function(val)
              if vb_notifiers_on then
                flags.fx_min = (val <= 255 and val) or 255
                queue_processing()
              end
            end
          
          },
          
          vb:horizontal_aligner { --aligns in column
            mode = "center",
            
            vb:button { --redistribute button
              id = "fx_re_button",
              tooltip = "Redistribute FX evenly throughout selection\n(based on FX Lo and FX Hi values)",
              bitmap = "Bitmaps/redistributelvls.bmp",
              width = "100%",
              notifier = function()
                flags.fx_re = not flags.fx_re
                if flags.fx_re then
                  vb.views.fx_re_button.color = theme.selected_button_back
                else 
                  vb.views.fx_re_button.color = {0,0,0}
                end
                queue_processing()
              end
            }
          }          
        } --close FX controls column 
        
      }, --close row
      
      vb:row {
      
        vb:horizontal_aligner { --aligns checkboxes and switches to window size
          mode = "justify",
          width = 220,
          --margin = default_margin,
        
          vb:column { --column containing our checkboxes
            style = "group",
          
            vb:button { 
              id = "overflow_button", 
              tooltip = "Overflow Mode",
              bitmap = "Bitmaps/overflow.bmp",
              width = 36,
              height = 20,
              notifier = function()
                if vb_notifiers_on then
                  flags.overflow = not flags.overflow
                  if flags.overflow then
                    vb.views.overflow_button.color = theme.selected_button_back
                  else 
                    vb.views.overflow_button.color = {0,0,0}
                  end
                  queue_processing()
                end
              end 
            },
            
            vb:button { 
              id = "condense_button",
              tooltip = "Condense Mode",
              bitmap = "Bitmaps/condense.bmp",
              width = 36,
              height = 20,
              notifier = function()
                if vb_notifiers_on then
                  flags.condense = not flags.condense
                  if flags.condense then
                    vb.views.condense_button.color = theme.selected_button_back
                  else 
                    vb.views.condense_button.color = {0,0,0}
                  end
                  queue_processing()
                end
              end 
            },
            
            vb:button { 
              id = "redistribute_button",
              tooltip = "Redistribute Mode",
              bitmap = "Bitmaps/redistribute.bmp",
              width = 36,
              height = 20,
              notifier = function()
                if vb_notifiers_on then
                  flags.redistribute = not flags.redistribute
                  if flags.redistribute then
                    vb.views.redistribute_button.color = theme.selected_button_back
                  else 
                    vb.views.redistribute_button.color = {0,0,0}
                  end
                  queue_processing()
                end
              end 
            }
          },  --close checkbox column
          
          vb:vertical_aligner { --aligns our switches to the bottom of the window
            mode = "bottom",
            --margin = default_margin,
            
            vb:row {
            
              vb:column {
                style = "group",
                --margin = default_margin,
                
                vb:switch {
                  width = 94,
                  id = "our_notes_flag_switch", 
                  tooltip = "In the event of our processed notes colliding with each other, which one should overwrite the other?",
                  items = {"Earlier","Later"},
                  value = 1, 
                  notifier = function(value)
                    if vb_notifiers_on then
                      if value == 1 then flags.our_notes = false
                      elseif value == 2 then flags.our_notes = true end
                      queue_processing()
                    end
                  end 
                },
                
                vb:switch {
                  width = 94,
                  id = "wild_notes_flag_switch", 
                  tooltip = "In the event of our processed notes colliding with notes outside of our selection, which one should overwrite the other?",
                  items = {"Not","Selected"},
                  value = 1, 
                  notifier = function(value)
                    if vb_notifiers_on then
                      if value == 1 then flags.wild_notes = false
                      elseif value == 2 then flags.wild_notes = true end
                      queue_processing()
                    end
                  end 
                }
              },
            
              vb:horizontal_aligner {
                mode = "right",
              
                vb:column { --column containing our switches
                  style = "group",
                  --margin = default_margin,
                
                  vb:switch {
                    id = "anchor_switch",
                    width = 64,
                    value = 1,
                    items = {"Top", "End"},
                    notifier = function(value)
                      if vb_notifiers_on then
                        anchor = value - 1
                        reposition_controls()
                        queue_processing()
                      end
                    end
                  },
                  
                  vb:switch {
                    id = "anchor_type_switch",
                    width = 64,
                    value = 1,
                    items = {"Note", "Select"},
                    notifier = function(value)
                      if vb_notifiers_on then
                        anchor_type = value
                        update_start_pos()
                        queue_processing()
                      end
                    end
                  }
                } --close switches column
              } --close switches horizontal aligner
            } --close switches vertical aligner
          } --close row
        } --close checkbox/switches horizontal aligner
      } --close row
    } --close window_content column
    
    if debugvars.extra_curve_controls then    
      local debugcurvecontrols = vb:column {
        
        vb:horizontal_aligner { --aligns in column
          mode = "center",
        
          vb:switch { 
            id = "curve_type_selector", 
            height = 16,
            width = 32,
            tooltip = "Curve Type",
            items = {"1","2"},
            value = 1,
            notifier = function(value)              
              if vb_notifiers_on then
                curve_type[1] = value
                update_curve_display(1)
                queue_processing()
              end
            end 
          }
        },
          
        vb:horizontal_aligner { --aligns in column
          mode = "center",
          
          vb:switch { 
            id = "drawing_mode", 
            height = 16,
            width = 32,
            tooltip = "Drawing Mode",
            items = {"Point","Line"},
            value = 2,
            notifier = function(value)              
              if vb_notifiers_on then
                if value == 1 then
                  drawmode = "point"
                else
                  drawmode = "line"
                end
                update_all_curve_displays()
                queue_processing()
              end
            end 
          }
        },
        
        vb:horizontal_aligner { --aligns in column
          mode = "center",
          
          vb:valuefield {
            id = "samplesize_text",
            tooltip = "Type exact sample size values here!",
            align = "center",
            min = 1,
            max = 256,
            value = 1,
            
            --tonumber converts any typed-in user input to a number value 
            --(called only if value was typed)
            tonumber = function(str)
              local val = str:gsub("[^0-9.-]", "") --filter string to get numbers and decimals
              val = tonumber(val) --this tonumber() is Lua's basic string-to-number converter
              if val and 1 <= val and val <= 256 then --if val is a number, and within min/max
                curve_points[1][curve_type[1]].samplesize = val
                update_curve_display(1)
                queue_processing()
              end
              return val
            end,
            
            --tostring is called when field is clicked, 
            --after tonumber is called,
            --and after the notifier is called
            --it converts the value to a formatted string to be displayed
            tostring = function(value)
              return ("%i pts"):format(value)
            end,        
            
            --notifier is called whenever the value is changed
            notifier = function(value)
            end
          } --close view item
        } --close aligner
      } --close column
      
      vb.views.curve_column:add_child(debugcurvecontrols)
      
    end --end "if debugvars.extra_curve_controls"    
  end --end "if not window_content" statement
    
  
  --key handler function (any unused modifiers/key states/etc will be commented out in case needed later)
  local function key_handler(dialog,key)
  
    if key.state == "pressed" then
      
      if not key.repeated then
      
        if key.modifiers == "" then
          
          if key.name == "esc" then dialog:close() end        
          if key.name == "space" then space_key() end          
          if key.name == "up" then up_key() end
          if key.name == "down" then down_key() end
          if key.name == "left" then left_key() end
          if key.name == "right" then right_key() end          
          if key.name == "tab" then tab_key() end
          
        elseif key.modifiers == "shift" then
        
          if key.name == "space" then shift_space_key() end          
          if key.name == "tab" then shift_tab_key() end
        
        --elseif key.modifiers == "alt" then
        
        elseif key.modifiers == "control" then
        
          if key.name == "space" then space_key() end
        
        --elseif key.modifiers == "shift + alt" then
        
        --elseif key.modifiers == "shift + control" then
        
        --elseif key.modifiers == "alt + control" then
        
        --elseif key.modifiers == "shift + alt + control" then
        
        end
      
      elseif key.repeated then
      
        if key.modifiers == "" then
        
          if key.name == "up" then up_key() end
          if key.name == "down" then down_key() end
          if key.name == "left" then left_key() end
          if key.name == "right" then right_key() end          
          if key.name == "tab" then tab_key() end
        
        elseif key.modifiers == "shift" then
        
          if key.name == "tab" then shift_tab_key() end
        
        --elseif key.modifiers == "alt" then
        
        --elseif key.modifiers == "control" then
        
        --elseif key.modifiers == "shift + alt" then
        
        --elseif key.modifiers == "shift + control" then
        
        --elseif key.modifiers == "alt + control" then
        
        --elseif key.modifiers == "shift + alt + control" then
        
        end
      
      end --end if key.repeated
      
    --elseif key.state == "released" then
    
      --if key.modifiers == "" then
      
      --elseif key.modifiers == "shift" then
      
      --elseif key.modifiers == "alt" then
      
      --elseif key.modifiers == "control" then
      
      --elseif key.modifiers == "shift + alt" then
      
      --elseif key.modifiers == "shift + control" then
      
      --elseif key.modifiers == "alt + control" then
      
      --elseif key.modifiers == "shift + alt + control" then
      
      --end
      
    end --end if key.state == "pressed"/"released"
    
  end --end key_handler()
  
  --key handler options
  local key_handler_options = {
    send_key_repeat = true,
    send_key_release = true
  }
  
  get_theme_data()
  
  set_theme_colors()
  
  --create the dialog if it show the dialog window
  if not window_obj or not window_obj.visible then
    window_obj = app:show_custom_dialog("Reform", window_content, key_handler, key_handler_options)
  else window_obj:show() end
  
  return true
end

--REFORM SELECTION-----------------------------------------------
local function reform_selection()
      
  local result = reset_variables()
  if result then result = add_document_notifiers() end
  if result then result = get_selection() end
  if result then result = find_selected_notes() end
  if result then result = calculate_note_placements() end
  if result then result = update_start_pos() end
  if result then result = get_theme_data() end
  if result then result = show_window() end
  if result then result = activate_controls() end
  if result then result = update_valuefields() end
  if result then result = update_all_curve_displays() end
  if result then result = reset_view() end

end

--RESTORE REFORM WINDOW----------------------------------------------------
local function restore_reform_window()

  if valid_selection then show_window() end
  
end

--MENU/HOTKEY ENTRIES-------------------------------------------------------------------------------- 

renoise.tool():add_menu_entry {
  name = "Pattern Editor:Reform Selection...", 
  invoke = function() reform_selection() end 
}

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Restore Reform Window", 
  invoke = function() restore_reform_window() end 
}

renoise.tool():add_keybinding {
  name = "Pattern Editor:Selection:Reform Selection", 
  invoke = function(repeated) if not repeated then reform_selection() end end
}

renoise.tool():add_keybinding {
  name = "Pattern Editor:Selection:Restore Reform Window", 
  invoke = function(repeated) if not repeated then restore_reform_window() end end
}
