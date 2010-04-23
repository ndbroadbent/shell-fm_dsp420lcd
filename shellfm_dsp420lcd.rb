#!/usr/bin/ruby
# Simple script that displays the artist and title from shell-fm
# on a DSP-420 LCD screen.
# Scrolls any strings that are longer than their allowed lengths.
# If a string is scrolled, it is padded with 2 spaces to the beginning and end.
# (easier to read)

require 'rubygems'
require 'serialport'
require 'socket'

# shell.fm network interface config
IP = "localhost"
PORT = "54311"

Update_delay = 4     # Delay between shell.fm refreshes.
Scroll_delay = 0.8   # speed of artist and title scrolling

# initialize serialport
@sp = SerialPort.new "/dev/ttyUSB0", 9600
@sp.flow_control = SerialPort::NONE

# Gets info from shell-fm
def shellfm_info
  # Gets the 'artist', 'title', and 'remaining seconds'
  cmd = "info %a||%t||%R"
  t = TCPSocket.new(IP, PORT)
  t.print cmd + "\n"
  info = t.gets(nil).split("||")
  t.close
  return info
  rescue
    # On error, returns -- artist: "", title: "shell.fm stopped.", remaining seconds: 0
    return ["", "shell.fm stopped.", "0"]
end

def hexctl(i)
  # converts an integer between 1 and 40 to its hex control character.
  "0x#{(i + 48).to_s(16)}".hex.chr
end

def clear_lcd(start_pos, end_pos)
  # Clears (C) all characters from start_pos to end_pos
  @sp.write 0x04.chr + 0x01.chr +
            "C" + hexctl(start_pos) + hexctl(end_pos) + 0x17.chr
end

def set_cursor(pos)
  # Sets cursor pos (P) to position 'pos' (between 1 and 40)
  @sp.write 0x04.chr + 0x01.chr + "P" + hexctl(pos) + 0x17.chr
end

def write_lcd(string, min = 1, max = 40, pre_clear = true)
  string = string[0, max-min+1]
  # Writes string to LCD.
  # The pre_clear var is a hack to fix a timing bug due to setting the cursor and then
  # writing data. It fixed the time not being displayed properly.
  clear_lcd(min, max) if pre_clear
  set_cursor(min)
  sleep 0.1 unless pre_clear
  @sp.write string
end

def center(str, length)
  # if a string is less than the max length, it pads spaces at the left to center it.
  if str.size < length
    lpad = ((length - str.size) / 2).to_i
    return " " * lpad + str
  end
  str
end

def format_time(t)
  min, sec = (t.to_i / 60), (t.to_i % 60)
  min, sec = 0, 0 if min < 0
  time = "%02d:%02d" % [min, sec]
end

# Scrolls the artist or title widget. (this method was just a hasty logic refactor..)
def scroll(widget, scroll_buffer)
  if widget[0].size > widget[3] and widget[1] != scroll_buffer
    str, scroll_pos, start_pos, length = *widget
    write_lcd (str[scroll_pos-1, str.size]), start_pos, (length + start_pos - 1)
    scroll_buffer = widget[1]
  end
  return widget[1]
end

def increment_scroll_pos(widget)
  # Only increment the scroll pos if we are actually scrolling..
  if widget[0].size > widget[3]
    str, scroll_pos = widget[0], widget[1]
    length = widget[3] || 20
    scroll_pos += 1
    scroll_pos = 1 if str[scroll_pos-1, str.size].size < length
    widget[0], widget[1] = str, scroll_pos
  end
end

def set_widget_values(str, scroll_pos, start_pos, length)
  # Pad the string with 2 spaces on either side if we are going to scroll it.
  str = "  #{str}  " if str.size > length
  # Write the data to the lcd as a centered string if it is below the max length.
  write_lcd center(str, length), start_pos, (length + start_pos - 1) if str.size <= length
  return [str, scroll_pos, start_pos, length]
end

# ----------- at_exit code ---------------------

at_exit {
  # When we quit, display a final "bye" message.
  write_lcd("        Bye!        ")
}

# -------------- Script Start -------------------

# Display initial splash screen
write_lcd("shell.fm LCD display" +
          "(c) Nathan Broadbent")
sleep 2

# Get our first reading from shellfm and initialize artist and title arrays,
# and write the first data to the lcd.
# Also set up buffers to keep track of value changes.
artist, title, remain = shellfm_info
remain = remain.to_f
@artist, ar_buf, ar_pos_buf = set_widget_values(artist, 1, 28, 13), artist, 1
@title, tt_buf, tt_pos_buf = set_widget_values(title, 1, 1, 20), title, 1
time = format_time(remain)
@time, tm_buf = [(time + "| "), 21, 6], time
write_lcd @time[0], @time[1], (@time[2] + @time[1]), false

# ------------------- Initialize threads -------------------

# Thread to periodically update our artist/title/remaining time hash and loop.
shellfm_refresh_thread = Thread.new {
  while true
    artist, title, remain = shellfm_info
    remain = remain.to_f
    sleep Update_delay
  end
}

# Thread to count down the remaining time between refreshes.
countdown_remain_thread = Thread.new {
  while true
    remain -= 1
    sleep 1
  end
}

# Thread to scroll track and artist.
scroll_thread = Thread.new {
  while true
    increment_scroll_pos(@artist)
    increment_scroll_pos(@title)
    sleep Scroll_delay
  end
}

# ------------------- Start main LCD loop -------------------

while true
  # set values if they have changed.
  if artist != ar_buf
    @artist = set_widget_values(artist, 1, 28, 13)
    ar_buf = artist
  end
  if title != tt_buf
    str, scroll_pos, start_pos, length = title, 1, 1, 20
    @title = set_widget_values(title, 1, 1, 20)
    tt_buf = title
  end

  ar_pos_buf = scroll(@artist, ar_pos_buf)
  tt_pos_buf = scroll(@title, tt_pos_buf)

  # Split the 0.1 delay between the track info and remaining time writes.
  # (Helps to stop overflowing the LCD buffer)
  sleep 0.05

  # Writes the remaining time data.
  time = format_time(remain)
  if time != tm_buf
    @time = [(time + "| "), 21, 6]
    tm_buf = time
    write_lcd @time[0], @time[1], (@time[2] + @time[1]), false
  end

  # Refresh our display every 0.1 seconds with any data that has changed.
  sleep 0.05
end

