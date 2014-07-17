class Heroku::Command::Docker < Heroku::Command::Base
 
  # docker:build
  #
  # create docker image from heroku app
  #
  # requires local docker binary
  #
  # -b, --base  # override default base image
  # -t, --tag   # specify a tag for the image
  #
  def build
    stack = api.get_app(app).body["stack"]

    base = options[:base] || case stack
      when "bamboo-ree-1.8.7" then "ddollar/heroku-bamboo"
      when "bamboo-mri-1.9.2" then "ddollar/heroku-bamboo"
      else error("Unsupported stack: #{stack}")
    end

    tag = options[:tag] || app

    releases = get_v3("/apps/#{app}/releases")
    latest   = releases.sort_by { |r| r["version"] }.last
    slug     = get_v3("/apps/#{app}/slugs/#{latest["slug"]["id"]}")

    env = env_minus_config(app)

    Dir.mktmpdir do |dir|
      write_dockerfile dir, base, slug["blob"]["url"], env
      build_image dir, tag
    end

    puts "Built image #{tag}"
  end

private

  def get_v3(uri)
    json_decode(heroku.get(uri, "Accept" => "application/vnd.heroku+json; version=3"))
  end

  def write_dockerfile(dir, base, url, env)
    envs = env.keys.sort.map { |key| "ENV #{key} #{env[key]}" }.join("\n")
    IO.write("#{dir}/Dockerfile", <<-DOCKERFILE)
      FROM #{base}
      RUN curl '#{url}' -o /slug.img
      RUN rm -rf /app
      RUN unsquashfs -d /app /slug.img
      RUN ls -la /app
      MKDIR /home/heroku_rack
      WORKDIR /home/heroku_rack
      RUN curl -L http://cl.ly/2k1p1K0i032f/heroku_rack.tgz | tar xz
      #{envs}
      WORKDIR /app
      EXPOSE 5000
      CMD thin -p 5000 -e ${RACK_ENV:-production} -R $HEROKU_RACK start
    DOCKERFILE
  end

  def build_image(dir, tag)
    system "docker build -t #{tag} #{dir}"
  end

  def env_minus_config(app)
    data = api.post_ps(app, "env", :attach => true).body
    buffer = StringIO.new
    rendezvous = Heroku::Client::Rendezvous.new(:rendezvous_url => data["rendezvous_url"], :output => buffer)
    rendezvous.start
    env = buffer.string.split("\n").inject({}) do |ax, line|
      name, value = line.split("=", 2)
      ax.update name => value
    end
    for name, value in api.get_config_vars(app).body do
      env.delete name
    end
    env
  end

end
