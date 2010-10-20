# encoding: utf-8

require 'set'
require 'curb'
require 'hpricot'

def get_news_text(page) 
   doc = Hpricot(page)
   return doc.search("//div[@class='noticia']").search("//p").to_s.gsub(/<[bB][Rr] \/><[bB][Rr] \/>/, "\n").gsub(/<\/?[^>]*>/, "")
end


def get_links(page)
   links = []
   page.each_line do |line|
      if /<a href="(http\:\/\/(?:www|(?:\w+))\.publico\.pt\/\w+\/[^[\_]]+\_\d+)"/ =~ line
         match = $1.gsub(/#.*$/, "")
         links << match
      elsif /<a href="(http\:\/\/(?:\w+)\.publico\.pt\/noticia\.aspx\?id=(?:\d+))"/ =~ line
         links << match
      elsif /<a href="(\/\w+\/[^[\_]]+\_\d+)"/ =~ line
         match = $1.gsub(/#.*$/, "")
         links << "http://publico.pt#{match}"
      end
   end
   return links
end


def get_serialized_set
   # if file with serialized data doesn't exist create one with a sample set
   begin
      serialized_file = File.new("set.txt", "r") 
   rescue Errno::ENOENT
      #File doesn't exists, fill it with sample data
      serialized_file = File.new("set.txt", "w")
      s_set = Set.new
      Marshal.dump(s_set,serialized_file)
      serialized_file.close
      serialized_file = File.new("set.txt", "r")
   end

   s_set = Marshal.load(serialized_file)
   serialized_file.close
   return s_set
end


def pop_top()
   link = nil
   @structsmut.synchronize {
      if (!@queue.empty?)
         link = @queue[0]
         @queue.delete_at(0)
      end
   }
   return link
end

def signal_processing_job
   @countmut.synchronize { @count += 1 }
end

def signal_job_ended
   @countmut.synchronize { @count -= 1 }
end

def kill_thread_if_no_active_jobs
   @countmut.synchronize { 
      if (@count == 0)
         Thread.current.kill
      end
   }
end

def file_write(text)
   @filemut.synchronize { @f << text }
end

def add_to_queue_and_set(links)
   links.each do |l|
      @structsmut.synchronize {
         unless (@set.include?(l))
            @set << l
            @queue << l
         end
      }
   end
end

def process_jobs
   while(true)   
      link = pop_top()
      
      if link.nil?
         Thread.pass
      else
         signal_processing_job()

         begin
            page = Curl::Easy.http_get(link).body_str
            file_write(get_news_text(page))
            links = get_links(page)
            
            add_to_queue_and_set(links)

            
         rescue RuntimeError
         rescue Exception
         end
         
         signal_job_ended()
      end
   end
end



@set = get_serialized_set()
@queue = []
@count = 0
@f = File.open("corpus.txt", "a")

@filemut = Mutex.new
@structsmut = Mutex.new
@countmut = Mutex.new

page = Curl::Easy.http_get("http://publico.pt").body_str
links = get_links(page)
add_to_queue_and_set(links)

(1..15).each {
   Thread.new {
        process_jobs()   
   }
}

exit_thread = nil
#watcher thread, when no more jobs at queue kill script
Thread.new {
   exit_thread = Thread.current

   while(true)
      sleep 20 # allow other threads to grab links
      kill_thread_if_no_active_jobs() 
      Thread.pass #this line only runs if there is there is still jobs on the queue
   end
}

while (exit_thread.nil?)
   #ensuring we don't make a join thread wasn't even able to run yet
   Thread.pass
end

exit_thread.join

serialized_file = File.new("set.txt", "w")
Marshal.dump(@set, serialized_file)
serialized_file.close