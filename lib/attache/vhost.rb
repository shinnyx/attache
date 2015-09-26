class Attache::VHost
  attr_accessor :remotedir,
                :secret_key,
                :bucket,
                :storage,
                :download_headers,
                :headers_with_cors,
                :env

  def initialize(hash)
    self.env = hash || {}
    self.remotedir  = env['REMOTE_DIR'] # nil means no fixed top level remote directory, and that's fine.
    self.secret_key = env['SECRET_KEY'] # nil means no auth check; anyone can upload a file
    if env['FOG_CONFIG']
      self.bucket       = env['FOG_CONFIG'].fetch('bucket')
      self.storage      = Fog::Storage.new(env['FOG_CONFIG'].except('bucket').symbolize_keys)
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

  def storage_get(args)
    url = remote_api.new({
      key: File.join(*remotedir, args[:relpath]),
    }).url(Time.now + 60)
    open(url)
  end

  def storage_create(args)
    Attache.logger.info "[JOB] uploading #{args[:cachekey].inspect}"
    remote_api.create({
      key: File.join(*remotedir, args[:relpath]),
      body: Attache.cache.read(args[:cachekey]),
    })
    Attache.logger.info "[JOB] uploaded #{args[:cachekey]}"
    Attache.outbox.delete(env['HOSTNAME'], args[:relpath]) if env['HOSTNAME'].present?
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
end
