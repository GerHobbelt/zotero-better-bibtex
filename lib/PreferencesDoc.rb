#!/usr/bin/env ruby

require 'nokogiri'
require 'ostruct'
require 'yaml'

class PreferencesDoc
  def doc(node)
    if node.children.length > 0
      doc = nil
      node.children.each{|child|
        case child.name
        when 'text' then # pass
        when 'comment'
          doc = child
          break
        else
          break
        end
      }
    else
      doc = node
      while doc.next_sibling && doc.next_sibling.name == 'text'
        doc = doc.next_sibling
      end
      doc = doc.next_sibling
    end

    return '' unless doc && doc.name == 'comment'

    return doc.inner_text.split("\n").collect{|line| line.strip }.join("\n") + "\n"
  end

  def initialize(config)
    dtd = File.expand_path(config.sources.detect{|f| File.extname(f) == '.dtd'})
    dtd = "[\n" + File.read(dtd) + "\n]"

    pane = config.sources.detect{|f| File.extname(f) == '.xul'}
    pane = File.read(pane)
    pane.sub!(/SYSTEM ".*?"/, dtd)
    #open('test.xml', 'w'){|f| f.puts(pane) }

    pane = Nokogiri::XML(pane) {|cfg| cfg.noent.strict }

    pane.xpath("//node()[name() = 'label']").each{|node|
      next unless node.next_element && (node.next_element['preference'] || node.next_element['docpreference']) && !node.next_element['label']
      node.next_element['label'] = node['value'] || node.inner_text
      throw node.next_element['preference'] if node.next_element['label'] == ''
    }

    panels = []
    prefs = []
    panel = -1
    preface = ''
    pane.xpath('//node()').each{|node|
      case node.name
      when 'prefpane'
        preface = doc(node)

      when 'preference'
        prefs << OpenStruct.new({name: node['name'], key: node['id'], type: node['type']})
        prefs[-1].bbt = true if node['name'] =~ /^extensions\.zotero\.translators\.better-bibtex\./
        prefs[-1].doc = doc(node)

        if prefs[-1].bbt
          name = prefs[-1].name.sub('extensions.zotero.translators.better-bibtex.', '')
          key = prefs[-1].key.sub('pref-better-bibtex-', '')
          throw "Fix id for #{prefs[-1].name}" unless name == key
        end
      when 'tab'
        panels << node['label'] if node['id'] != 'better-bibtex-prefs-disabled'
      when 'tabpanel'
        panel += 1
      end

      next unless node['preference'] || node['docpreference']

      pref = prefs.detect{|p| p.key == node['preference'] || p.key == node['docpreference']}
      throw "#{node['preference']} not found" unless pref
      pref.panel = panels[panel]
      pref.label = node['label'] if node['label']
      pref.doc += doc(node)

      if node.name == 'radiogroup'
        node.xpath(".//node()[name()='radio']").each{|option|
          d = doc(option)
          next if d == ''
          pref.doc += "* **#{option['label']}**: " + d
        }
      end
    }

    supported = YAML::load_file(config.sources.detect{|f| File.extname(f) == '.yml'})
    supported.keys.each{|k|
      supported["extensions.zotero.translators.better-bibtex.#{k}"] = supported[k]
      supported.delete(k)
    }

    prefs.each{|pref|
      next unless pref.bbt
      next unless supported[pref.name].nil?
      throw "Unsupported pref #{pref.name}"
      puts "No label for #{pref.name}" unless pref.label
    }
    undocumented = []
    supported.each_pair{|name, default|
      type = case default
        when Fixnum then 'int'
        when TrueClass, FalseClass then 'bool'
        when String then 'string'
        else '??'
      end

      pref = prefs.detect{|p| p.name == name }
      if pref
        pref.default = default
      else
        id = name.sub('extensions.zotero.translators.better-bibtex.', 'pref-better-bibtex-').gsub('.', '-')
        undocumented << "<preference name=\"#{name}\" id=\"#{id}\" type=\"#{type}\"/>"
      end
    }
    if undocumented.length > 0
      puts "Undocumented:"
      puts undocumented.join("\n")
      exit(1)
    end

    undocumented = []
    prefs.each{|pref|
      next unless pref.bbt
      next if pref.doc && pref.doc != ''
      undocumented << pref.inspect
    }
    if undocumented.length > 0
      puts "Undocumented:"
      puts undocumented.join("\n")
      exit(1)
    end

    markdown = """
      <!-- DO NOT EDIT THIS FILE ON THE GITHUB WIKI
            This page is generated automatically from comments in
            https://github.com/retorquere/zotero-better-bibtex/blob/master/chrome/content/zotero-better-bibtex/preferences/preferences.xul.
            Any edits made directly in this file will be overwritten the next time it is generated.
      -->
    """.split("\n").collect{|line| line.strip}.join("\n")
    markdown += preface + "\n\n"

    panels.each{|panel|
      markdown += "\n\n## #{panel}\n\n"
      prefs.select{|pref| pref.panel == panel}.each{|pref|
        next unless pref.bbt
        throw "Unlabelled #{pref.inspect}" if pref.label.nil? || pref.label == ''
        if pref.default.is_a?(String) && pref.default.length > 10
          default = pref.default[0,10] + '...'
        elsif pref.default.is_a?(String) && pref.default == ''
          default = "`empty`"
        else
          default = pref.default
        end
        markdown += "\n\n### #{pref.label}\n*default: #{default}*\n\n"
        markdown += pref.doc
      }
    }

    markdown += "\n\n## Hidden preferences\n\n"
    prefs.reject{|pref| pref.panel}.each{|pref|
      next unless pref.bbt
      if pref.default.is_a?(String) && pref.default.length > 10
        default = pref.default[0,10] + '...'
      elsif pref.default.is_a?(String) && pref.default == ''
        default = "`empty`"
      else
        default = pref.default
      end
      markdown += "\n\n### #{pref.name}\n*default: #{default}*\n\n"
      markdown += pref.doc
    }

    markdown.gsub!(/\n\n+/, "\n\n")

    open(config.name, 'w'){|f| f.puts(markdown) }
  end
end

if __FILE__ == $0
  PreferencesDoc.new(OpenStruct.new({
    sources: [
      'Rakefile',
      'defaults/preferences/defaults.yml',
      'chrome/content/zotero-better-bibtex/preferences/preferences.xul',
      'chrome/locale/en-US/zotero-better-bibtex/zotero-better-bibtex.dtd',
    ],
    name: 'wiki/Configuration.md'
  }))
end
