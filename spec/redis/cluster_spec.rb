# frozen_string_literal: true
require 'redis-cluster'
require 'pry'

describe Redis::Cluster do
  subject{ described_class.new(nodes, cluster_opts: { read_mode: :slave }) }
  let(:nodes){ [ 'redis://127.0.0.1:7001' ] }

  describe '#silent?' do
    it{ is_expected.not_to be_silent }
  end

  describe '#logger' do
    it{ expect(subject.logger).to be_nil }
  end

  describe '#pipeline?' do
    it do
      is_expected.not_to be_pipeline

      subject.pipelined do
        is_expected.to be_pipeline
      end
    end
  end

  describe '#close' do
    it{  expect{ subject.close }.not_to raise_error }
  end

  describe '#connected?' do
    it{ is_expected.not_to be_connected }
  end

  describe '#safety' do
    subject{ described_class.new(nodes, cluster_opts: { read_mode: :slave, silent: true }) }

    it do
      expect{ subject.call(:del, 'wow', 'wew') }.not_to raise_error
    end
  end

  let(:all_redis) do
    all = []
    mapping = subject.random.call([:cluster, :slots])
    mapping.map do |arr|
      all.concat(arr[2..-1].map{ |h, p| "redis://#{h}:#{p}" })
    end

    return all
  end

  describe '#random' do
    it{ expect(all_redis).to be_include(subject.random.url) }
  end

  describe '#reset' do
    it 'work' do
      expect{ subject.reset }.not_to raise_error
    end

    it 'can retry 3 times' do
      old_count = subject.clients.count
      allow(subject).to receive(:slots_and_clients).and_raise(StandardError)

      expect{ subject.reset }.to raise_error(StandardError)
      expect(subject.clients.count).to eql (old_count - 3)
    end
  end

  describe '#[]' do
    let(:url){ 'redis://127.0.0.1:7003' }
    it do
      client = subject[url]
      expect(client).not_to be_nil
      expect(client).to eql subject.clients[url]
    end
  end

  describe '#slot_for_key' do
    it do
      expect(subject.slot_for_key('wow')).to eql 2300
      expect(subject.slot_for_key('wow')).to eql subject.slot_for_key('coba{wow}aja{hahah}')
    end
  end

  describe '#master/master_slave/slave_for' do
    let(:expected_url) do
      mapping = subject.random.call([:cluster, :slots])
      mapping.each do |arr|
        return arr[2..-1].map{ |h, p| "redis://#{h}:#{p}" } if (arr[0]..arr[1]).cover?(2300)
      end
    end

    it do
      expect(subject.master(2300).url).to eql expected_url.first
      expect(expected_url[1..-1].include? subject.slave(2300).url).to be_truthy
      expect(expected_url.include? subject.master_slave(2300).url).to be_truthy
    end
  end

  describe '#call & #pipelined' do
    context 'stable cluster' do
      it do
        expect do
          subject.call(:set, 'waw', 'waw')
          subject.call(:set, 'wew', 'wew')
          subject.call(:set, 'wiw', 'wiw')
          subject.call(:set, 'wow', 'wow')
          subject.call(:set, 'wuw', 'wuw')

          subject.call(:get, 'waw', read: true)
          subject.call(:get, 'wew', read: true)
          subject.call(:get, 'wiw', read: true)
          subject.call(:get, 'wow', read: true)
          subject.call(:get, 'wuw', read: true)
        end.not_to raise_error

        a, e, i, o, u = nil
        expect do
          subject.pipelined do
            a = subject.call(:get, 'waw')
            e = subject.call(:get, 'wew')
            i = subject.call(:get, 'wiw')
            o = subject.call(:get, 'wow')
            u = subject.call(:get, 'wuw')
          end
        end.not_to raise_error

        expect(a.value).to eql 'waw'
        expect(e.value).to eql 'wew'
        expect(i.value).to eql 'wiw'
        expect(o.value).to eql 'wow'
        expect(u.value).to eql 'wuw'
      end
    end

    context 'migrating' do
      it do
        expect do
          subject.call(:set, '{slot}1', '1')
          subject.call(:set, '{slot}2', '2')

          slot = subject.slot_for_key('slot')
          cluster = subject.random.call([:cluster, :slots]).map do |from, to, master|
            # master[0]:master[1] is an url, master[2] is redis node-id
            [(from..to).cover?(slot), "redis://#{master[0]}:#{master[1]}", master[2]]
          end
          from = cluster.select{ |info| info.first }.first
          to = cluster.reject{ |info| info.first }.first
          from_client = subject[from[1]]
          to_client = subject[to[1]]

          # set slot to migrating state
          to_client.call([:cluster, :setslot, slot, :importing, from.last])
          from_client.call([:cluster, :setslot, slot, :migrating, to.last])
          from_client.call([:migrate, to_client.url.split(':').first, to_client.url.split(':').last, '{slot}2', 0, 5000])

          # ask redirection should occurs
          subject.call(:get, '{slot}2')
          subject.pipelined do
            subject.call(:get, '{slot}1')
            subject.call(:get, '{slot}2')
          end

          from_client.call([:migrate, to_client.url.split(':').first, to_client.url.split(':').last, '{slot}1', 0, 5000])
          from_client.call([:cluster, :setslot, slot, :node, to.last])
          to_client.call([:cluster, :setslot, slot, :node, to.last])

          # move redirection should occures
          subject.call(:get, '{slot}2')
          subject.pipelined do
            subject.call(:get, '{slot}1')
            subject.call(:get, '{slot}2')
          end
        end.not_to raise_error
      end
    end

    context 'server down' do
      def safely
        yield
      rescue Redis::CannotConnectError
        sleep 1
        retry
      rescue Redis::FutureNotReady
        sleep 1
        retry
      rescue Redis::CommandError => e
        err = e.to_s.split.first.downcase.to_sym
        raise e unless err == :clusterdown
        sleep 1
        retry
      end


      it do
        slot = subject.slot_for_key('wow')
        slot_port = subject.master(slot).url.split(':').last.to_i
        File.new('.circleci/tmp/pid', 'r').each_with_index do |l, i|
          `kill -9 #{l}` if slot_port - 7001 == i
        end

        value = nil
        expect do
          safely do
            subject.call(:set, 'wow', 'wow')
            value = subject.call(:get, 'wow', read: true)
          end
        end.not_to raise_error
        expect(value).to eq 'wow'

        slot = subject.slot_for_key('wew')
        slot_port = subject.master(slot).url.split(':').last.to_i
        File.new('.circleci/tmp/pid', 'r').each_with_index do |l, i|
          `kill -9 #{l}` if slot_port - 7001 == i
        end

        expect do
          safely do
            subject.pipelined do
              subject.call(:set, 'wew', 'wew')
              value = subject.call(:get, 'wew', read: true)
            end
          end
        end.not_to raise_error
        expect(value.value).to eq 'wew'
      end
    end
  end

  it 'can handle race condition' do
    subject.call(:set, 'wew', 'wew')

    t = Thread.new do
      subject.pipelined do
        sleep 5
        a = subject.call(:get, 'wew', read: true)
      end

      expect(a).to be_a Redis::Cluster::Future
    end

    sleep 1
    b = subject.call(:get, 'wew', read: true)

    expect(b).to eql 'wew'
  end
end
