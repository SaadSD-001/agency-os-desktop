require 'open3'
require 'json'
require 'yaml'
require 'date'
require 'digest'
require 'base64'
require 'tmpdir'
REPO = 'SaadSD-001/agency-os-desktop'
TAG = ENV.fetch('RELEASE_TAG')
abort 'Unexpected release tag' unless TAG.match?(/\Av\d+\.\d+\.\d+\z/)

def gh(*args)
  stdout, stderr, status = Open3.capture3('gh', *args, '-R', REPO)
  abort stderr unless status.success?
  stdout
end
def release(tag=nil)
  JSON.parse(gh('release','view', *[tag].compact, '--json','tagName,isDraft,isPrerelease,assets'))
end
def assets(r)
  r.fetch('assets').to_h { |a| [a.fetch('name'),a] }
end
def download(tag, name, expected)
  gh('release','download',tag,'-p',name,'-O',name)
  abort "Bad asset digest for #{name}" unless expected == 'sha256:' + Digest::SHA256.file(name).hexdigest
end
def carry(name, from_digest)
  existing = assets(release(TAG))[name]
  if existing
    abort "Different bytes already exist at #{name}" unless existing['digest'] == from_digest
  else
    gh('release','upload',TAG,name)
  end
end

target = release(TAG)
exit if target['isDraft'] || target['isPrerelease'] || release()['tagName'] != TAG
checking = ENV['GITHUB_EVENT_NAME'] == 'workflow_dispatch' && assets(target).key?('latest-mac.yml')
exit if !checking && assets(target).key?('latest-mac.yml')
# Some publishers create the release before uploading the Windows manifest.
10.times do
  target = release(TAG)
  exit if !checking && assets(target).key?('latest-mac.yml')
  break if assets(target).key?('latest.yml')
  sleep 20
end
abort 'Publish a complete platform feed first, then rerun this workflow.' unless assets(target).key?('latest.yml')
tags = JSON.parse(gh('release','list','--exclude-drafts','--exclude-pre-releases','--limit','100','--json','tagName')).map { |r| r['tagName'] }
older = tags.select { |t| t.match?(/\Av\d+\.\d+\.\d+\z/) && Gem::Version.new(t[1..]) < Gem::Version.new(TAG[1..]) }
source = checking ? target : older.sort_by { |t| Gem::Version.new(t[1..]) }.reverse.lazy.map { |t| release(t) }.find { |r| assets(r).key?('latest-mac.yml') }
abort 'No previous stable Mac feed' unless source
Dir.mktmpdir do |tmp|
  Dir.chdir(tmp) do
    origin = source['tagName']
    files = assets(source)
    manifest = 'latest-mac.yml'
    download(origin,manifest,files.fetch(manifest).fetch('digest'))
    feed = YAML.safe_load_file(manifest,permitted_classes:[Date,Time])
    version = feed.fetch('version')
    abort 'Invalid version' unless version.match?(/\A\d+\.\d+\.\d+\z/)
    entries = feed.fetch('files')
    names = %w[arm64 x64].map { |arch| "SND-Media-#{version}-mac-#{arch}.zip" }
    abort 'Expected a complete Mac feed' unless entries.map { |e| e['url'] }.sort == names.sort
    entries.each do |e|
      name = e['url']
      download(origin,name,files.fetch(name).fetch('digest'))
      abort 'Mac ZIP differs from manifest' unless File.size(name)==e['size'] && Base64.strict_encode64(Digest::SHA512.file(name).digest)==e['sha512']
      carry(name,files.fetch(name).fetch('digest'))
      map = name+'.blockmap'
      download(origin,map,files.fetch(map).fetch('digest'))
      carry(map,files.fetch(map).fetch('digest'))
    end
    exit if assets(release(TAG)).key?(manifest)
    carry(manifest,files.fetch(manifest).fetch('digest'))
    puts "Preserved macOS #{version} on #{TAG}"
  end
end
