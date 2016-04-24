class Attache::VHost
  attr_accessor :remotedir,
                :secret_key,
                :backup,
                :bucket,
                :storage,
                :download_headers,
                :headers_with_cors,
                :geometry_whitelist,
                :env

  def initialize(hash)
    self.env = hash || {}
    self.remotedir  = env['REMOTE_DIR'] # nil means no fixed top level remote directory, and that's fine.
    self.secret_key = env['SECRET_KEY'] # nil means no auth check; anyone can upload a file
    self.geometry_whitelist = env['GEOMETRY_WHITELIST'] # nil means everything is acceptable

    if env['FOG_CONFIG']
      self.bucket       = env['FOG_CONFIG'].fetch('bucket')
      self.storage      = Fog::Storage.new(env['FOG_CONFIG'].except('bucket').symbolize_keys)

      if env['BACKUP_CONFIG']
        backup_fog = env['FOG_CONFIG'].merge(env['BACKUP_CONFIG'])
        self.backup = Attache::VHost.new(env.except('BACKUP_CONFIG').merge('FOG_CONFIG' => backup_fog))
      end
    end
    self.download_headers = {
      "Cache-Control" => "public, max-age=31536000"
    }.merge(env['DOWNLOAD_HEADERS'] || {})
    self.headers_with_cors = {
      'Access-Control-Allow-Origin' => '*',
      'Access-Control-Allow-Methods' => 'POST, PUT',
      'Access-Control-Allow-Headers' => 'Content-Type',
    }.merge(env['UPLOAD_HEADERS'] || {})
  end

  def hmac_for(content)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), secret_key, content)
  end

  def hmac_valid?(params)
    params['uuid'] &&
    params['hmac']  &&
    params['expiration'] &&
    Time.at(params['expiration'].to_i) > Time.now &&
    Rack::Utils.secure_compare(params['hmac'], hmac_for("#{params['uuid']}#{params['expiration']}"))
  end

  def storage_url(args)
    object = remote_api.new({
      key: File.join(*remotedir, args[:relpath]),
    })
    result = if object.respond_to?(:url)
      object.url(Time.now + 600)
    else
      object.public_url
    end
  ensure
    Attache.logger.info "storage_url: #{result}"
  end

  def storage_get(args)
    open storage_url(args)
  end

  def storage_create(args)
    Attache.logger.info "[JOB] uploading #{args[:cachekey].inspect}"
    body = begin
      Attache.cache.read(args[:cachekey])
    rescue Errno::ENOENT
      :no_entry # upload file no longer exist; likely deleted immediately after upload
    end
    unless body == :no_entry
      remote_api.create({
        key: File.join(*remotedir, args[:relpath]),
        body: body,
      })
      Attache.logger.info "[JOB] uploaded #{args[:cachekey]}"
    end
  end

  def storage_destroy(args)
    Attache.logger.info "[JOB] deleting #{args[:relpath]}"
    remote_api.new({
      key: File.join(*remotedir, args[:relpath]),
    }).destroy
    Attache.logger.info "[JOB] deleted #{args[:relpath]}"
  end

  def remote_api
    storage.directories.new(key: bucket).files
  end

  def async(method, args)
    ::Attache::Job.perform_async(method, env, args)
  end

  def authorized?(params)
    secret_key.blank? || hmac_valid?(params)
  end

  def unauthorized
    [401, headers_with_cors.merge('X-Exception' => 'Authorization failed'), []]
  end

  def backup_file(args)
    if backup
      key = File.join(*remotedir, args[:relpath])
      storage.copy_object(bucket, key, backup.bucket, key)
    end
  end
end
