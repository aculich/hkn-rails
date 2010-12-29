#!/usr/bin/env ruby
#
# Imports a CSV dump of the GoodProfOrNot database.
#
# mysqldump --fields-terminated-by=, goodprofornot
#
# Usage: import_course_surveys <your/dump/path>
#
# Changelog:
# jonathanko 12/20/10: doin it
#
# TODO: Maybe some logging.
#
require 'optparse'          # useful for DRY options

# GoodProfOrNot Schema:
# [db: goodprofornot]
#  [table: answer]
#    Field            Type                   Null
#    ============================================
#    "id"             "int(10) unsigned"     "NO"
#    "klassid"        "smallint(5) unsigned" "NO"
#    "questionid"     "smallint(5) unsigned" "NO"
#    "frequencies"    "varchar(255)"         "NO"
#    "mean"           "float"                "YES"
#    "deviation"      "float"                "YES"
#    "median"         "float"                "YES"
#    "orderinsurvey"  "smallint(5) unsigned" "NO"
#    "instructorid"   "smallint(5) unsigned" "YES"


# A useful helper
class Array

    # Returns an array of hashes, with each line in the input file mapped to a
    # hash according to the specified fields.
    #
    # Options:
    #   remove_slashes: remove slashes like in \, that were added to avoid problems
    #                   with CSV'ing strings containing commas.
    #
    def self.from_csv(file=nil, fields=nil, options={})
        raise ArgumentError if file.nil? or fields.nil?
        options = {:remove_slashes => true}.update(options)
        
        IO.readlines(file).collect do |line|
            h = {}
            # Ruby < 1.9 doesn't support negative lookbehinds.. wtf.
            # I'd like to do:
            #   /(?<!\\)\,[\s]*/
            # i.e. split on commas that aren't escaped.
            #
            # What we do instead is scan for each field.
            # A field is a run of chars that aren't ',' by itself (can still have
            # \, to indicate that a comma is part of the field). Match this zero
            # or more times (can have empty fields denoted by field1,,field3).
            # Then consume the comma and spaces. For good measure, also don't
            # include line breaks in the field matcher.
            #
            # Zip field names (hash keys) with scanned values to get an array of
            # KV pairs.
            #
            #                      _____fields____     delims
            #                     /               \   /      \
            fields.zip(line.scan(/((?:\\,|[^,\r\n])*)(?:,\s*)?/)).each do |kv|
                kv[1].first.gsub!(/\\/, '') if options[:remove_slashes]
                h[kv[0]] = kv[1].first
            end
            h
        end
    end
end

class Integer
    def to_bool
        (self == 0 ? false : true)
    end
end

class CourseSurveyImporter
# Puts GoodPOrN in your databases.
#

# Former table fields, used to import CSV
@@answer_fields = [:id, :klassid, :questionid, :frequencies, :mean, :deviation, :median, :orderinsurvey, :instructorid]
@@instructor_fields = [:id, :firstname, :lastname, :departmentid, :role, :title, :divisionid, :phone, :fax, :email, :office, :url, :comment_url, :assistant, :interests, :current, :most_recent_class, :picture_url, :private]
@@question_fields = [:id, :text, :subject, :important, :inverted, :ratingmax, :short, :keyword]
@@klass_fields = [:id, :courseid, :seasonid, :year, :section, :url]
@@season_fields = [:id, :name, :fraction]
@@course_fields = [:id, :coursename, :coursenumber, :level, :departmentid, :description, :url, :units, :current, :prerequisites, :newsgroup]
@@department_fields = [:id, :name, :abbrev]
@@instructorship_fields = [:klassid, :instructorid]

# Hashes of former id => new object
# Yes, these lines don't actually do anything, but looks like you have to
# initialize things in initialize() to have any effect.
@instructors
@questions
@klasses
@seasons
@courses
@departments
@answers

# dump path
@dpath = nil

@options = {}
attr_accessor :options

def initialize
    @instructors, @questions, @klasses, @seasons, @courses, @departments, @answers = {}, {}, {}, {}, {}, {}, {}
    @options = {}
end

def initialize_BAD(dumpfolder)
# Argument: /path/to/dump/
# This importer will look for dumpfolder/[table name].txt's.
    @dpath = dumpfolder
    @instructors, @questions, @klasses, @seasons, @courses, @departments, @answers = {}, {}, {}, {}, {}, {}, {}
#    @options = {:verbose => true}
end

def import!(options)
    raise "ERROR: no dump path provided!" unless @dpath = options[:from]

    load_instructors
    load_questions
    load_seasons
    load_departments
    load_courses
    load_klasses
    load_instructorships
    load_answers
    
    # Here's the plan:
    # Coursesurvey: Represents an administration of a course survey. Has nothing
    #               to do with the survey data.
    # SurveyQuestions: Actual questions like "How hot was this prof?"
    # SurveyAnswers: Represents aggregate response to one question of one
    #               Coursesurvey
    # Instructor: Referenced by SurveyAnswer
    # Klass: Also referenced by SurveyAnswer, represents a semester of a class
    # Course: Referenced by Klass
    # Season: Summer, Fall, or Spring.
end

def dumpfilename(tablename)
    File.join(File.expand_path(@dpath, File.dirname(__FILE__)), "#{tablename}.txt")
end

def load_cache_hash(filename)
    # Returns true if successful, false on IO errors
    # provide a block of |old_id, new_id| for operations

    raise "Provide a block of |old_id, new_id|." unless block_given?
    begin
        File.open(filename, "r") do |f|
            puts "Reading cache file #{filename}... "
            num_entries = f.readline.match(/entries ([0-9]+)/i)[1].to_i
            if num_entries.nil? then
                puts "Malformed cache file #{filename}, no data loaded.\n"
                return
            end

            f.readlines.each do |line|
                line.gsub!(/\r\n/,'')
                old_id, new_id = line.split(' ')
                yield old_id.to_i, new_id.to_i
                num_entries -= 1
            end
            
            raise "Incomplete cache file #{filename}, expected #{num_entries} more. Only some data was loaded.\n" unless num_entries == 0
        end
        puts "Done.\n\n"
        return true
    rescue
        puts "Couldn't load cache file #{filename}.\n"
        return false
    end
end

def write_cache_hash(filename, h)
    # Writes a hash of old_id => new object to file
    #
    # Format:
    #   entries [#]
    #   [old_id] [new_id]
    #   ...
    
    begin
        File.open(filename, "w") do |f|
            puts "Writing cache file #{filename}... "
            f.write("entries #{h.length}\n")
            h.each_pair do |old_id, new_i|
                f.write("#{old_id} #{new_i.id}\n")
            end # h.each_pair
            
        end # IO.open
        puts "Done.\n"
        return true
    rescue
        puts "WARNING: Couldn't save cache file #{filename}\n"
        return false
    end

end

def load_instructors
    # Load instructor data.
    # Updates or creates new instructors. Any existing data is not overwritten,
    # except the 'private' attribute is set equal to loaded value.
    #
    return if @options[:skip].include?(:instructors)
    instructor_map_cache_file = "instructors.cache"
    
    puts "Loading instructors.\n"
    
    # Cache mappings
    return if load_cache_hash(instructor_map_cache_file) do |old_id, new_id|
        @instructors[old_id] = Instructor.find(new_id)
    end
    
    puts "Rebuilding.\n"
    
    instructors = Array.from_csv(dumpfilename("instructor"), @@instructor_fields, {:remove_slashes=>true} )
    instructors.each do |i|
        # Convert to booleans.
        [:private, :current].each { |k| i[k]=i[k].to_i.to_bool }
        
        # Convert to ints
        [:id, :departmentid, :divisionid].each {|k| i[k]=i[k].to_i}

        # Link to our new representation
        new_i = Instructor.find_or_create_by_first_name_and_last_name(i[:firstname], i[:lastname])
        # Update some attribs from i => new_i
        # Note: the ||= makes it UPDATE only. If any existing info is there, the
        # existing info won't be overwritten.
        {:email => :email, :role => :title, :phone => :phone_number, :office => :office, :private => :private, :url => :home_page, :interests => :interests, :picture_url => :picture}.each_pair do |old_attrib, new_attrib|
            if old_attrib == :private then
                # Special case: private defaults to true, so ||= won't do anything.
                new_i[:private] = i[:private]
            else
                # For all other attributes, update nil values.
                new_i[new_attrib] ||= i[old_attrib]
            end
        end

        raise "ERROR: load_instructors: Failed to save instructor:\n\n\t#{new_i.inspect}\n\n" unless new_i.save
        
        puts "load_instructors: Created/updated #{new_i.first_name} #{new_i.last_name} (new id #{new_i.id})\n" if @options[:verbose]
        
        # Save reference to newly created object, mapped by old id
        @instructors[i[:id]] = new_i
    end # instructors.each
    
    # Write to cache map
    write_cache_hash(instructor_map_cache_file, @instructors)
    
    puts "Done loading instructors.\n\n"
end # load_instructors

def load_questions
    return if @options[:skip].include?(:questions)
    puts "Loading questions.\n"
    questions = Array.from_csv(dumpfilename("question"), @@question_fields)
    questions.each do |q|
        new_q = SurveyQuestion.find_or_create_by_text(q[:text])

        # Map old keywords => new keywords
        keymap = {"tep" => :prof_eff, "teta" => :ta_eff, "ww" => :worthwhile}
        keymap.default = :none
        q[:keyword] = keymap[q[:keyword]]
        
        # Cast to integer
        q[:ratingmax] = q[:ratingmax].to_i
        
        # Cast to bool
        [:important, :inverted].each do |attrib|
            q[attrib] = q[attrib].to_i.to_bool
        end
        
        # Map old attribs => new attribs
        {:text=>:text, :important=>:important, :inverted=>:inverted, :ratingmax=>:max}.each_pair do |old_attrib, new_attrib|
            new_q[new_attrib] = q[old_attrib]
        end
        
        # Special case: have to use keyword= method; new_q[:keyword]= doesn't work
        new_q.keyword = q[:keyword]
        
        # Integerify
        q[:id] = q[:id].to_i
        
        unless new_q.save
            puts "ERROR: failed to save question\n\n\t#{new_q.inspect}\n\n"
            next
        end
        @questions[q[:id]] = new_q
        
        puts "Created/updated question #{new_q.text}" if @options[:verbose]
    end # questions.each
    puts "Done loading questions.\n\n"
end # load_questions

def load_courses
    return if @options[:skip].include?(:courses)
    puts "Loading courses."
    
    courses = Array.from_csv(dumpfilename("course"), @@course_fields)
    courses.each do |c|
        # Integerize some attribs
        [:id, :departmentid, :units].each do |key|
            c[key] = c[key].to_i
        end
        
        (prefix, course_number, suffix) = c[:coursenumber].scan(/^([a-zA-Z]*)([0-9]*)([a-zA-Z]*)$/).first
        
        # lol
        new_c = Course.find_or_create_by_department_id_and_prefix_and_course_number_and_suffix(@departments[c[:departmentid]].id, prefix, course_number, suffix)
        
        # Map attribs
        {:coursename => :name, :description => :description, :units => :units, :prerequisites => :prereqs}.each_pair do |old_attrib, new_attrib|
            new_c[new_attrib] = c[old_attrib]
        end
        
        # Special cases
        
        # Some imported courses don't have names b/c they're not offered anymore.
        # Courses have to have names to be saved, so we do a minor hack.
        new_c[:name] = "[ INVALID COURSE ]" if new_c[:name].blank?
        
        
        
        # TODO: is this right?
        #       EE20N:
        #       prefix = something that's not EE.. i haven't seen these before
        #       course_number = 20
        #       suffix = N
        # TODO: what is new attrib 'level'?
        
        unless new_c.save
            raise "Couldn't save course #{new_c.inspect} because #{new_c.errors}!"
        end
        
        puts "Loaded course #{new_c.course_abbr}\n" if @options[:verbose]
        
        @courses[c[:id]] = new_c        
    end # courses.each
    
    puts "Done loading courses.\n\n"
end

def load_seasons
    return if @options[:skip].include?(:seasons)
    puts "Loading seasons."
    
    seasons = Array.from_csv(dumpfilename("season"), @@season_fields)
    seasons.each do |s|
        s[:id] = s[:id].to_i
        @seasons[s[:id]] = s
        puts "Loaded season #{s[:name]}." if @options[:verbose]
        
        # There's no new Season/Semester model (it's stored as a string in klass).
        
    end
    
    puts "Done loading seasons.\n\n"
end

def load_departments
    return if @options[:skip].include?(:departments)
    puts "Loading departments."
    
    departments = Array.from_csv(dumpfilename("department"), @@department_fields)
    departments.each do |d|
        d[:id] = d[:id].to_i
        
        dept = Department.find_or_create_by_name(d[:name])
        dept.abbr = d[:abbrev]
        unless dept.save
            puts "ERROR: Failed to load department #{dept.inspect}\n"
        end
        
        @departments[d[:id]] = dept
        
        puts "Loaded department #{d[:name]} (#{d[:abbrev]})." if @options[:verbose]
    end # departments.each
    
    puts "Done loading departments.\n\n"
end

def load_klasses
    return if @options[:skip].include?(:klasses)
    puts "Loading klasses."

    klasses_map_cache_file = "klasses.cache"

    # Cache mappings
    return if load_cache_hash(klasses_map_cache_file) do |old_id, new_id|
        @klasses[old_id] = Klass.find(new_id)
    end
    
    klasses = Array.from_csv(dumpfilename("klass"), @@klass_fields)
    klasses.each do |k|
        # Integerize
        [:id, :courseid, :seasonid, :section].each do |attrib|
            k[attrib] = k[attrib].to_i
        end

        # Semester is like "20103" = "#{year}{season.number}"
        # with season numbers as defined in klass.
        #
        #
        # Source: coursesurveys_controller.klass
        #
        #           semester = year+season_no
        #
        sem_id = -1
        Klass::SEMESTER_MAP.each_pair do |sid, sname|
            if @seasons[k[:seasonid]][:name].downcase.eql?(sname.downcase) then
                sem_id = sid
                break
            end
        end
        semester = "#{k[:year]}#{sem_id}"

        new_k = Klass.find_or_create_by_course_id_and_semester(@courses[k[:courseid]].id, semester)

        # Map attribs
        {:section => :section}.each_pair do |old_attrib, new_attrib|
            new_k[new_attrib] = k[old_attrib]
        end

        # Special processing
        new_k[:notes] = "Imported url: #{k[:url]}" unless k[:url].eql?("N")

        raise "ERROR: couldn't save klass #{new_k.inspect}" unless new_k.save

        # TODO: time? location? num_students? This info isn't available for import.
        
        puts "Loaded klass #{new_k.course.course_abbr} #{@seasons[k[:seasonid]][:name]} #{k[:year]}\n"

        @klasses[k[:id]] = new_k
    end # klasses.each
    
    # Write to cache map
    write_cache_hash(klasses_map_cache_file, @klasses)
    
    puts "Done loading klasses.\n\n"
end

def load_instructorships
    return if @options[:skip].include?(:instructors_klasses)

    puts "Loading instructor-klass relationships."
    
    instructorships = Array.from_csv(dumpfilename("instructor_klass"), @@instructorship_fields)
    
    instructorships.each_index do |index|      
        i = instructorships[index]
        i[:klassid] = @klasses[i[:klassid].to_i].id
        i[:instructorid] = @instructors[i[:instructorid].to_i].id
        
        raise "Couldn't find klass #{i[:klassid]}!" if (the_klass=Klass.find(i[:klassid])).nil?
        raise "Couldn't find instructor #{i[:instructorid]}!" if (the_instructor=Instructor.find(i[:instructorid])).nil?
        
        unless the_klass.instructor_ids.include?(i[:instructorid])
            the_klass.instructor_ids << the_instructor 
            raise "Error saving instructor-klass relationship!" unless the_klass.save
        end
        
        puts "Created/updated instructorship #{index}/#{instructorships.length} of #{the_instructor.full_name} for #{the_klass.to_s}" if @options[:verbose]
    end
    
    puts "Done loading instructor-klass.\n\n"
end

def load_answers
    return if @options[:skip].include?(:answers)

    puts "Loading answers."

    answers_map_cache_file = "answers.cache"

    # Cache mappings
    return if load_cache_hash(answers_map_cache_file) do |old_id, new_id|
        @answers[old_id] = SurveyAnswer.find(new_id)
    end

    answers = Array.from_csv(dumpfilename("answer"), @@answer_fields)
    answers.each_index do |index|
        a = answers[index]
        
        # Integerize
        [:id, :klassid, :questionid, :orderinsurvey, :instructorid].each do |attrib|
            a[attrib] = a[attrib].to_i
        end
        
        # Floatize
        [:mean, :median, :deviation].each do |attrib|
            a[attrib] = a[attrib].to_f
        end
        
        
        # Find existing answer, or do weird stuff to create a new one
        new_klass_id, new_instructor_id, new_question_id = @klasses[a[:klassid]].id, @instructors[a[:instructorid]].id, @questions[a[:questionid]].id
#        new_a = SurveyAnswer.find_by_klass_id_and_instructor_id_and_survey_question_id(new_klass_id, new_instructor_id, new_question_id) || SurveyAnswer.new(:klass_id=>new_klass_id, :instructor_id=>new_instructor_id, :survey_question_id=>new_question_id)
        conditions = {:klass_id=>new_klass_id, :instructor_id=>new_instructor_id, :survey_question_id=>new_question_id}
        new_a = SurveyAnswer.find(:first, :conditions => conditions) || SurveyAnswer.send(:new, conditions)
        
        # Map attribs
        {:mean => :mean, :deviation => :deviation, :median => :median, :orderinsurvey => :order, :frequencies => :frequencies}.each_pair do |old_attrib, new_attrib|
            new_a[new_attrib] = a[old_attrib]
        end
        
        raise "Couldn't save answer #{new_a.inspect} because #{new_a.errors}!" unless new_a.save

        @answers[a[:id]] = new_a
        puts "Created/updated answer (#{index}/#{answers.length}) ##{new_a.order} for #{new_a.instructor.full_name} for #{new_a.klass.to_s}" if @options[:verbose]
    end # answers.each
    
    # Write to cache map
    write_cache_hash(answers_map_cache_file, @answers)

    puts "Done loading answers.\n\n"    
end

end # class CourseSurveyImporter





# int main(argc, char **argv) {
@csi = CourseSurveyImporter.new #(ARGV.first)

parser = OptionParser.new do |opts|
    opts.banner = "Usage: import_course_surveys [options] /path/to/dumpfolder"
    {:verbose => false, :clear => false, :skip => []}.each_pair do |option, value|
        @csi.options[option] = value
    end
    
    opts.on('-v', '--verbose', 'Output more detailed information (warning: spammy)') do
        @csi.options[:verbose] = true
    end
    opts.on('-h', '--help', 'Display this screen') do
        puts opts
        exit 0
    end
    opts.on('-s', '--skip TABLE', 'Skip table <instructors|courses|klasses|questions|answers|instructors_klasses|seasons|departments>') do |table|
        @csi.options[:skip] << table.to_sym
    end
#    opts.on('-c', '--clear', 'Clear tables before operating') do
#        @csi.options[:clear] = true
#    end
end
parser.parse!

if ARGV.empty?
    puts parser.help
    exit -1
else
    puts "Warming up... please wait."

    require 'rubygems'          # needed for activesupport
    require 'active_support'    # needed for json
    require File.expand_path('../../../../config/environment', __FILE__) # needed for hkn-rails classes

    @csi.import!(:from => ARGV.first)
end
puts "\nAll done.\n"
# }
