require 'fpm/fry/detector'
require 'rubygems/package/tar_header'
describe FPM::Fry::Detector::Container do

  let(:client){
    cl = double(:client)
    allow(cl).to receive(:read){ raise FPM::Fry::Client::FileNotFound }
    allow(cl).to receive(:read_content){ raise FPM::Fry::Client::FileNotFound }
    cl
  }

  subject{
    FPM::Fry::Detector::Container.new(client, 'doesntmatter')
  }

  class TarEntryMock < StringIO
    attr :header

    def initialize(string, options = {})
      super(string)
      options = {name: "", size: 0, prefix: "", mode: 0777}.merge(options)
      @header = Gem::Package::TarHeader.new(options)
    end

  end

  it 'reads /etc/lsb-release' do
    expect(client).to receive(:read_content).with(
                        'doesntmatter','/etc/lsb-release'
                      ).and_return(<<LSB)
DISTRIB_ID=foo
Random trash
DISTRIB_RELEASE=1234
LSB
    subject.detect!
    expect(subject.distribution).to eq('foo')
    expect(subject.version).to eq('1234')
  end

  it 'reads /etc/debian_version' do
    expect(client).to receive(:read_content).with(
                        'doesntmatter','/etc/debian_version'
                      ).and_return(<<LSB)
6.0.5
LSB
    subject.detect!
    expect(subject.distribution).to eq('debian')
    expect(subject.version).to eq('6.0.5')
  end

  it 'reads /etc/redhat-release' do
    expect(client).to receive(:read_content).with(
                        'doesntmatter','/etc/redhat-release'
                      ).and_return(<<LSB)
Foobar release 1.33.7
LSB
    subject.detect!
    expect(subject.distribution).to eq('foobar')
    expect(subject.version).to eq('1.33.7')
  end

end

describe FPM::Fry::Detector::Image do

  let(:client){
    cl = double(:client)
    allow(cl).to receive(:url){|*args| args.join('/') }
    cl
  }

  let(:container_detector){
    double(:container_detector)
  }

  let(:factory){
    f = double(:factory)
    allow(f).to receive(:new).and_return(container_detector)
    f
  }

  subject{
    FPM::Fry::Detector::Image.new(client, 'doesntmatter', factory)
  }

  it "creates an image an delegates to its factory" do
    expect(client).to receive(:post).and_return(double(body: '{"Id":"deadbeef"}'))
    expect(client).to receive(:delete).with(path: 'containers/deadbeef')
    expect(container_detector).to receive(:detect!).and_return(true)
    expect(container_detector).to receive(:distribution).and_return("foo")
    expect(container_detector).to receive(:version).and_return("1.2.3")
    expect(container_detector).to receive(:codename).and_return("bar")
    expect(container_detector).to receive(:flavour).and_return("debian")
    expect( subject.detect! ).to be true
  end

  it "raises a pointful error message for non-existing images" do
    expect(client).to receive(:post).and_raise(Excon::Errors::NotFound.new("Not found"))
    expect{ subject.detect! }.to raise_error FPM::Fry::Detector::Image::ImageNotFound, /Image "doesntmatter" not found/
  end

  context 'with ubuntu:16.04' do
    subject{
      FPM::Fry::Detector::Image.new(real_docker, 'ubuntu:16.04')
    }

    it 'finds ubuntu 16.04' do
      real_docker.pull('ubuntu:16.04')
      expect(subject.detect!).to be true
      expect(subject.distribution).to eq('ubuntu')
      expect(subject.version).to eq('16.04')
      expect(subject.codename).to eq('xenial')
      expect(subject.flavour).to eq('debian')
    end
  end

  context 'with ubuntu:14.04' do
    subject{
      FPM::Fry::Detector::Image.new(real_docker, 'ubuntu:14.04')
    }

    it 'finds ubuntu 14.04' do
      real_docker.pull('ubuntu:14.04')
      expect(subject.detect!).to be true
      expect(subject.distribution).to eq('ubuntu')
      expect(subject.version).to eq('14.04')
      expect(subject.codename).to eq('trusty')
      expect(subject.flavour).to eq('debian')
    end
  end

  context 'with ubuntu:12.04' do
    subject{
      FPM::Fry::Detector::Image.new(real_docker, 'ubuntu:12.04')
    }

    it 'finds ubuntu 12.04' do
      real_docker.pull('ubuntu:12.04')
      expect(subject.detect!).to be true
      expect(subject.distribution).to eq('ubuntu')
      expect(subject.version).to eq('12.04')
      expect(subject.codename).to eq('precise')
      expect(subject.flavour).to eq('debian')
    end
  end

  context 'with debian:7' do
    subject{
      FPM::Fry::Detector::Image.new(real_docker, 'debian:7')
    }

    it 'finds debian 7' do
      real_docker.pull('debian:7')
      expect(subject.detect!).to be true
      expect(subject.distribution).to eq('debian')
      expect(subject.version).to match(/\A7\.\d+/)
      expect(subject.codename).to eq('wheezy')
      expect(subject.flavour).to eq('debian')
    end
  end

  context 'with debian:8' do
    subject{
      FPM::Fry::Detector::Image.new(real_docker, 'debian:8')
    }

    it 'finds debian 8' do
      real_docker.pull('debian:8')
      expect(subject.detect!).to be true
      expect(subject.distribution).to eq('debian')
      expect(subject.version).to match(/\A8\.\d+/)
      expect(subject.codename).to eq('jessie')
      expect(subject.flavour).to eq('debian')
    end
  end

  context 'with centos:centos6' do
    subject{
      FPM::Fry::Detector::Image.new(real_docker, 'centos:centos6')
    }

    it 'finds centos 6' do
      real_docker.pull('centos:centos6')
      expect(subject.detect!).to be true
      expect(subject.distribution).to eq('centos')
      expect(subject.version).to match /\A6\.\d+\z/
      expect(subject.flavour).to eq('redhat')
    end
  end

  context 'with centos:centos7' do
    subject{
      FPM::Fry::Detector::Image.new(real_docker, 'centos:centos7')
    }

    it 'finds centos 7' do
      real_docker.pull('centos:centos7')
      expect(subject.detect!).to be true
      expect(subject.distribution).to eq('centos')
      expect(subject.version).to match /\A7\.\d+\.\d+/
      expect(subject.flavour).to eq('redhat')
    end
  end
end
