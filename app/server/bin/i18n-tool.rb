#!/usr/bin/env ruby

require 'kramdown'
require 'gettext'
require 'gettext/po'
require 'gettext/po_parser'
require 'optparse'
require 'fileutils'
require 'pp'

# i18n-tool --translate [lang]
# i18n-tool --import [lang]
# i18n-tool --update [lang]

$lang = nil
$task = nil


OptionParser.new do |opts|
  opts.banner = "Usage: i18n-tool.rb [options]"
  opts.on('-t', '--translate [LANG]', 'creates translated files from .po and English tutorial') do |l|
    $lang = l
    $task = :translate
  end
  opts.on('-i', '--import [LANG]', 'import existing non-.po translation to .po (one time only)') do |l|
    $lang = l
    $task = :import
  end
  opts.on('-u', '--update [LANG]', 'update language .po file with changes from English tutorial') do |l|
    $lang = l
    $task = :update
  end
end.parse!


$po = GetText::PO.new
if $task != :import then
  parser = GetText::POParser.new
  parser.ignore_fuzzy = false
  parser.report_warning = false
  parser.parse_file("sonic-pi-tutorial-#{$lang}.po", $po)
end
$pot = GetText::PO.new


class KramdownToOurMarkdown < Kramdown::Converter::Kramdown
  # slightly alters the behaviour of ruby kramdown gem's converter
  # TODO: send these as config options to upstream devs

  def convert_a(el, opts)
    # ruby kramdown wants to use document-wide link list footnotes,
    # but we prefer inline links instead
    if el.attr['href'].empty? then
      "[#{inner(el, opts)}]()"
    elsif el.attr['href'] =~ /^(?:http|ftp)/ || el.attr['href'].count("()") > 0
      "[#{inner(el, opts)}](#{el.attr['href']})"
    else
      title = parse_title(el.attr['title'])
      "[#{inner(el, opts)}](#{el.attr['href']}#{title})"
    end
  end
        
end


def handle_entry(msgid, msgstr, filename, line, flags = [])
  reference = "#{filename}:#{line}"
  if $pot.has_key?msgid then
    entry = $pot[msgid]
  else
    entry = GetText::POEntry.new(:normal)
    entry.msgid = msgid
  end
  entry.flags |= flags
  entry.references << reference
  if $task == :import then
    if msgid != msgstr then
      entry.flags |= ["fuzzy"]
      entry.msgstr = msgstr
    else
      entry.msgstr = ""
    end
  end
  $pot[msgid] = entry
  if $po.has_key?msgid then
    return $po[msgid].msgstr || msgid
  else
    return msgid
  end
end


def convert_element(filename, el, el2, bullet = nil)
  case el.type
  
  when :root, :li, :ul, :ol
    i = 0
    while (i < el.children.count) && (i < el2.children.count) do
      case el.type
      when :ul
        b = '*'
      when :ol
        b = "#{i+1}."
      else
        b = nil
      end
      convert_element(filename, el.children[i], el2.children[i], b)
      i += 1
    end

    if $task == :import then
      if el.children.count != el2.children.count then
        warn "Import: Unequal number of :#{el.type} elements #{el.children.count} != #{el2.children.count} in #{filename}"
      end
    end

  when :blank
    if $task == :translate then
      $translated[filename] += el.value.gsub(/' '/, '')
    end

  when :p
    if $task == :import then
      if el.type != el2.type then
        warn "Import #{filename}: element type mismatch #{el.type}(#{el.options[:location]}) != #{el2.type}(#{el2.options[:location]})"
      end
    end
    
    root = Kramdown::Element.new(
      :root, nil, nil,
      :encoding => "UTF-8",
      :location => 1,
      :options => {},
      :abbrev_defs => {}, :abbrev_attr => {}
    )
    root.children = [el]
    output, warnings = KramdownToOurMarkdown.convert(root)
    output.gsub!(/\n/, ' ').strip!

    root2 = Kramdown::Element.new(
      :root, nil, nil,
      :encoding => "UTF-8",
      :location => 1,
      :options => {},
      :abbrev_defs => {}, :abbrev_attr => {}
    )
    root2.children = [el2]
    output2, warnings = KramdownToOurMarkdown.convert(root2)
    output2.gsub!(/\n/, ' ').strip!
    
    t = handle_entry(output, output2, filename, el.options[:location])

    if $task == :translate then
      if bullet then
        $translated[filename] += bullet + " "
      end
      $translated[filename] += t + "\n"
    end
    
  when :codeblock
    if $task == :import then
      if el.type != el2.type then
        warn "Import #{filename}: element type mismatch #{el.type}(#{el.options[:location]}) != #{el2.type}(#{el2.options[:location]})"
      end
    end

    t = handle_entry(el.value.gsub(/\n+$/, ""), el2.value.gsub(/\n+$/, ""), filename, el.options[:location], ["no-wrap"])

    if $task == :translate then
      $translated[filename] += "```\n" + t + "\n" + "```\n"
    end
    
  when :header
    if $task == :import then
      if el.type != el2.type then
        warn "Import #{filename}: element type mismatch #{el.type}(#{el.options[:location]}) != #{el2.type}(#{el2.options[:location]})"
      end
    end
    
    t = handle_entry(el.options[:raw_text].strip, el2.options[:raw_text].strip, filename, el.options[:location])

    if $task == :translate then
      $translated[filename] += ("#" * el.options[:level]) + " " + t + "\n"
    end
    
  else
    raise "Error, please implement conversion for unknown Kramdown element type :#{el.type}"
  end
end

$translated = {}

Dir["en/*.md"].sort.each do |path|
  puts path
  basename = File.basename(path)
  $translated[basename] = ""
  
  content = IO.read(path, :encoding => 'utf-8')
  content = content.to_s
  content.gsub!(/\`\`\`\`*/, '~~~~')
  k = Kramdown::Document.new(content)
  
  if $task == :import then
    if File.exist?"#{$lang}/#{basename}" then
      content2 = IO.read("#{$lang}/#{basename}", :encoding => 'utf-8')
      content2 = content2.to_s
      content2.gsub!(/\`\`\`\`*/, '~~~~')
      k2 = Kramdown::Document.new(content2)
    else
      k2 = k
    end
  else
    k2 = k
  end
  
  convert_element(basename, k.root, k2.root)
end

puts ("-" * 40)

if $task == :translate then
  FileUtils::rm_rf "generated/#{$lang}"
  FileUtils::mkdir "generated/#{$lang}"
  $translated.each do |filename, newcontent|
    puts filename
    File.open("generated/#{$lang}/#{filename}", 'w') do |f|
      f << newcontent
    end
  end
elsif $task == :import then
  puts $pot.to_s
end
