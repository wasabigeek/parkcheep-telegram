module Parkcheep
  class GoogleMaps
    # @param [Parkcheep::CoordinateGroup] destination
    # @param [Array<Parkcheep::Carpark>] carparks
    def self.static_url(destination:, carparks: [])
      center_lat_lng = [destination.latitude, destination.longitude].join(",")
      url =
        "https://maps.googleapis.com/maps/api/staticmap?key=" +
          ENV["GOOGLE_MAPS_API_KEY"] # &signature=#{}
      url += "&size=500x500"
      # destination parameters
      url += "&markers=color:red|#{center_lat_lng}"
      # carpark parameters
      carpark_markers =
        carparks.to_enum.with_index.map do |carpark, index|
          labels = %w[A B C D E F G H I J]
          coordinate_group = carpark.coordinate_group
          "&markers=color:yellow|label:#{labels[index]}|#{coordinate_group.latitude},#{coordinate_group.longitude}"
        end
      url += carpark_markers.join if carpark_markers.any?

      url
    end
  end
end
