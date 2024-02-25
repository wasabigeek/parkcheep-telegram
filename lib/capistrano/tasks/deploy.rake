namespace :deploy do
  task :started do
    on roles(:bot, select: -> (s) { s.properties.platform == :hatchbox }) do
      upload! "deploy/parkcheep-telegram.env", "/home/deploy/#{fetch(:application)}/shared/"
      upload! "deploy/parkcheep-telegram.service",
              "/home/deploy/#{fetch(:application)}/shared/"
    end
  end

  task :published do
    on roles(:bot, select: -> (s) { s.properties.platform == :hatchbox }) do
      within("/home/deploy/#{fetch(:application)}/current") do
        execute "bundle",
                "install",
                "--without",
                "development",
                "test"
      end
      execute "cp",
              "/home/deploy/#{fetch(:application)}/shared/parkcheep-telegram.service",
              "/home/deploy/.config/systemd/user/",
              "-v"
      execute "systemctl", "--user", "daemon-reload"
      execute "systemctl", "--user", "restart", "parkcheep-telegram.service"
    end
  end
end
