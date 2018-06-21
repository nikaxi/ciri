# frozen_string_literal: true

# Copyright (c) 2018, by Jiang Jinyang. <https://justjjy.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


require 'spec_helper'
require 'ciri/evm'
require 'ciri/evm/account'
require 'ciri/forks/frontier'
require 'ciri/utils'
require 'ciri/db/backend/memory'
require 'ciri/chain/transaction'
require 'ciri/key'

RSpec.describe Ciri::EVM do

  before(:all) do
    prepare_ethereum_fixtures
  end

  parse_account = proc do |address, v|
    address = Ciri::Types::Address.new Ciri::Utils.hex_to_data(address)
    balance = Ciri::Utils.hex_to_number(v["balance"])
    nonce = Ciri::Utils.hex_to_number(v["nonce"])
    code = Ciri::Utils.hex_to_data(v["code"])
    storage = v["storage"].map do |k, v|
      [Ciri::Utils.hex_to_data(k), Ciri::Utils.hex_to_data(v).rjust(32, "\x00".b)]
    end.to_h
    Ciri::EVM::Account.new(address: address, balance: balance, nonce: nonce, storage: storage, code: code)
  end

  build_transaction = proc do |t_template, args|
    key = Ciri::Key.new(raw_private_key: Ciri::Utils.hex_to_data(t_template['secretKey']))
    transaction = Ciri::Chain::Transaction.new(
      data: Ciri::Utils.hex_to_data(t_template['data'][args['data']]),
      gas_limit: Ciri::Utils.hex_to_number(t_template['gasLimit'][args['gas']]),
      gas_price: Ciri::Utils.hex_to_number(t_template['gasPrice']),
      nonce: Ciri::Utils.hex_to_number(t_template['nonce']),
      to: Ciri::Types::Address.new(Ciri::Utils.hex_to_data(t_template['to'])),
      value: Ciri::Utils.hex_to_number(t_template['value'][args['value']])
    )
    transaction.sign_with_key!(key)
    transaction
  end

  run_test_case = proc do |test_case, prefix: nil|
    test_case.each do |name, t|

      context "#{prefix} #{name}" do

        # transaction
        transaction_arguments = t['transaction']

        env = t['env'] && t['env'].map {|k, v| [k, Ciri::Utils.hex_to_data(v)]}.to_h

        # env
        block_info = env && Ciri::EVM::BlockInfo.new(
          coinbase: env['currentCoinbase'],
          difficulty: env['currentDifficulty'],
          gas_limit: env['currentGasLimit'],
          number: env['currentNumber'],
          timestamp: env['currentTimestamp'],
        )

        t['post'].each do |fork_name, configs|
          it fork_name do
            configs.each do |config|
              state = Ciri::DB::Backend::Memory.new
              # pre
              t['pre'].each do |address, v|
                account = parse_account[address, v]
                state[account.address.to_s] = account
              end

              indexes = config['indexes']
              transaction = build_transaction[transaction_arguments, indexes]
              transaction.validate!

              # expect(Ciri::Utils.data_to_hex transaction.get_hash).to eq config['hash']
              transaction.sender

              evm = Ciri::EVM.new(state: state)
              evm.execute_transaction(transaction, block_info: block_info, ignore_exception: true)

              if config['logs']
                expect(Ciri::Utils.data_to_hex evm.logs_hash).to eq config['logs'][2..-1]
              end

              # # post
              # output = t['out'].yield_self {|out| out && Ciri::Utils.hex_to_data(out)}
              # if output
              #   # padding vm output, cause testcases return length is uncertain
              #   vm_output = (vm.output || '').rjust(output.size, "\x00".b)
              #   expect(vm_output).to eq output
              # end
              #
              # gas_remain = t['gas'].yield_self {|gas_remain| gas_remain && Ciri::Utils.big_endian_decode(Ciri::Utils.hex_to_data(gas_remain))}
              # expect(vm.machine_state.gas_remain).to eq gas_remain if gas_remain
              #
              # account = parse_account[address, v]
              # vm_account = state[account.address]
              # storage = account.storage.map {|k, v| [Ciri::Utils.data_to_hex(k), Ciri::Utils.data_to_hex(v)]}.to_h
              # vm_storage = if vm_account
              #                vm_account.storage.map {|k, v| [Ciri::Utils.data_to_hex(k), Ciri::Utils.data_to_hex(v)]}.to_h
              #              else
              #                {}
              #              end
              # expect(vm_storage).to eq storage
              # expect(vm_account).to eq account
            end
          end
        end
      end

    end
  end

  # these tests are slow
  skip_test_cases = %w{
    fixtures/GeneralStateTests/stRevertTest/LoopCallsThenRevert.json
    fixtures/GeneralStateTests/stRevertTest/LoopCallsDepthThenRevert.json
    fixtures/GeneralStateTests/stRevertTest/LoopCallsDepthThenRevert2.json
    fixtures/GeneralStateTests/stRevertTest/LoopCallsDepthThenRevert3.json
    fixtures/GeneralStateTests/stRevertTest/LoopDelegateCallsDepthThenRevert.json
  }.map {|f| [f, true]}.to_h

  skip_topics = %w{
    fixtures/GeneralStateTests/stQuadraticComplexityTest
    fixtures/GeneralStateTests/stRandom
    fixtures/GeneralStateTests/stRandom2
    fixtures/GeneralStateTests/stWalletTest
    fixtures/GeneralStateTests/stMemoryStressTest
    fixtures/GeneralStateTests/stTransactionTest
    fixtures/GeneralStateTests/stSolidityTest
    fixtures/GeneralStateTests/stSystemOperationsTest
  }.map {|f| [f, true]}.to_h

  Dir.glob("fixtures/GeneralStateTests/*").each do |topic|
    # skip topics
    if skip_topics.include? topic
      skip topic
      next
    end

    Dir.glob("#{topic}/*.json").each do |t|
      if skip_test_cases.include?(t)
        skip t
        next
      end

      run_test_case[JSON.load(open t), prefix: topic]
    end
  end

end