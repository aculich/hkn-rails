class Event < ActiveRecord::Base

  # === List of columns ===
  #   id          : integer 
  #   name        : string 
  #   slug        : string 
  #   location    : string 
  #   description : text 
  #   start_time  : datetime 
  #   end_time    : datetime 
  #   created_at  : datetime 
  #   updated_at  : datetime 
  # =======================

  validates :name, :presence => true
  validate :valid_time_range

  # Note on slugs: http://googlewebmastercentral.blogspot.com/2009/02/specify-your-canonical.html 

  def valid_time_range
    if !start_time.blank? and !end_time.blank?
      errors[:base] << "Start time must be less than end time" unless start_time < end_time
    end
  end
end