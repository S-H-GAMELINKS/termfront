# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "openssl"

class TestNetworkSecurity < Minitest::Test
  def test_connection_uses_peer_and_hostname_verification
    conn = Termfront::Network::Connection.new
    ctx = conn.send(:build_ssl_context, ca_file: nil)

    assert_equal OpenSSL::SSL::VERIFY_PEER, ctx.verify_mode
    assert_equal true, ctx.verify_hostname
  end

  def test_connection_builds_peer_info_from_certificate
    cert, = build_self_signed_certificate("localhost")
    conn = Termfront::Network::Connection.new
    peer_info = conn.send(:build_peer_info, cert)

    assert_match(/\A[0-9a-f]{64}\z/, peer_info.certificate_sha256)
    assert_match(/\A[0-9a-f]{64}\z/, peer_info.public_key_sha256)
    assert_includes peer_info.subject, "localhost"
    assert_kind_of Time, peer_info.not_after
  end

  def test_certificate_identity_check_detects_hostname_mismatch
    ca_key, ca_cert = build_ca
    cert, = build_server_certificate(ca_key, ca_cert, dns_names: ["localhost"])

    assert_equal true, OpenSSL::SSL.verify_certificate_identity(cert, "localhost")
    assert_equal false, OpenSSL::SSL.verify_certificate_identity(cert, "127.0.0.1")
  end

  def test_custom_ca_file_adds_trust_for_signed_server_certificate
    Dir.mktmpdir do |dir|
      ca_key, ca_cert = build_ca
      cert, = build_server_certificate(ca_key, ca_cert, dns_names: ["localhost"])
      ca_file = File.join(dir, "ca.pem")
      File.write(ca_file, ca_cert.to_pem)

      conn = Termfront::Network::Connection.new
      default_store = conn.send(:build_cert_store, ca_file: nil)
      custom_store = conn.send(:build_cert_store, ca_file: ca_file)

      assert_equal false, default_store.verify(cert)
      assert_equal true, custom_store.verify(cert)
    end
  end

  def test_self_signed_server_certificate_is_not_trusted_by_default_store
    cert, = build_self_signed_certificate("localhost")
    conn = Termfront::Network::Connection.new
    store = conn.send(:build_cert_store, ca_file: nil)

    assert_equal false, store.verify(cert)
  end

  def test_server_loads_fullchain_and_exposes_intermediates
    Dir.mktmpdir do |dir|
      ca_key, ca_cert = build_ca
      cert, key = build_server_certificate(ca_key, ca_cert, dns_names: ["localhost"])
      cert_path = File.join(dir, "fullchain.pem")
      key_path = File.join(dir, "privkey.pem")
      File.write(cert_path, cert.to_pem + ca_cert.to_pem)
      File.write(key_path, key.to_pem)

      old_cert = ENV["TERMFRONT_TLS_CERT_FILE"]
      old_key = ENV["TERMFRONT_TLS_KEY_FILE"]
      ENV["TERMFRONT_TLS_CERT_FILE"] = cert_path
      ENV["TERMFRONT_TLS_KEY_FILE"] = key_path

      server = Termfront::Network::Server.new
      loaded_cert, loaded_key, chain = server.send(:load_or_create_cert)

      assert_equal cert.to_der, loaded_cert.to_der
      assert_equal key.to_der, loaded_key.to_der
      assert_equal 1, chain.size
      assert_equal ca_cert.to_der, chain.first.to_der
    ensure
      ENV["TERMFRONT_TLS_CERT_FILE"] = old_cert
      ENV["TERMFRONT_TLS_KEY_FILE"] = old_key
    end
  end

  private

  def build_ca
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=Termfront Test CA")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600

    ext = OpenSSL::X509::ExtensionFactory.new
    ext.subject_certificate = cert
    ext.issuer_certificate = cert
    cert.add_extension(ext.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(ext.create_extension("keyUsage", "keyCertSign,cRLSign", true))
    cert.add_extension(ext.create_extension("subjectKeyIdentifier", "hash"))
    cert.add_extension(ext.create_extension("authorityKeyIdentifier", "keyid:always"))
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    [key, cert]
  end

  def build_server_certificate(ca_key, ca_cert, dns_names: [])
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(10_000)
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{dns_names.first}")
    cert.issuer = ca_cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600

    ext = OpenSSL::X509::ExtensionFactory.new
    ext.subject_certificate = cert
    ext.issuer_certificate = ca_cert
    cert.add_extension(ext.create_extension("basicConstraints", "CA:FALSE", true))
    cert.add_extension(ext.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
    cert.add_extension(ext.create_extension("extendedKeyUsage", "serverAuth"))
    cert.add_extension(ext.create_extension("subjectAltName", dns_names.map { |name| "DNS:#{name}" }.join(",")))
    cert.sign(ca_key, OpenSSL::Digest::SHA256.new)
    [cert, key]
  end

  def build_self_signed_certificate(common_name)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(10_000)
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    [cert, key]
  end
end
