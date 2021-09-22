#!/bin/bash -e
# This script is an experiment to clone litecoin into a 
# brand new coin + blockchain.
# The script will perform the following steps:
# 1) create first a docker image with ubuntu ready to build and run the new coin daemon
# 2) clone GenesisH0 and mine the genesis blocks of main, test and regtest networks in the container (this may take a lot of time)
# 3) clone litecoin
# 4) replace variables (keys, merkle tree hashes, timestamps..)
# 5) build new coin
# 6) run 4 docker nodes and connect to each other
# 
# By default the script uses the regtest network, which can mine blocks
# instantly. If you wish to switch to the main network, simply change the 
# CHAIN variable below

# change the following variables to match your new coin
COIN_NAME="Luascoin"
COIN_UNIT="LIC"
# 42 million coins at total (litecoin total supply is 84000000)
TOTAL_SUPPLY=88000000
MAINNET_PORT="8808"
MAINRPC_PORT="8803"
TESTNET_PORT="5588"
TESTRPC_PORT="5583"
PHRASE="September 21, 2021 Provigen Networks: Now accepting CaramenElectrastripclubsinthenorthshorealongwiththewestmajiogishnayways!"
# First letter of the wallet address. Check https://en.bitcoin.it/wiki/Base58Check_encoding
PUBKEY_CHAR="55"
# number of blocks to wait to be able to spend coinbase UTXO's
COINBASE_MATURITY=25
# leave CHAIN empty for main network, -regtest for regression network and -testnet for test network
CHAIN=""
# this is the amount of coins to get as a reward of mining the block of height 1. if not set this will default to 50
PREMINED_AMOUNT=1000000

# warning: change this to your own pubkey to get the genesis block mining reward
GENESIS_REWARD_PUBKEY=46e05270f6d736f006cb682c9e15998e3505e6185475f7e1a9bc5a4965984b6933ed8988336006ad07d0b5ae408bf5805183c5a94ab376d0e50f0c51ab30f6662

# dont change the following variables unless you know what you are doing
LITECOIN_BRANCH=master
GENESISHZERO_REPOS=https://github.com/lhartikk/GenesisH0
LITECOIN_REPOS=https://github.com/SovCoinX/SovCoin/
LITECOIN_PUB_KEY=040184710fa689ad5023690c80f3a49c8f13f8d45b8c857fbcbc8bc4a8e4d3eb4b10f4d4604fa08dce601aaf0f470216fe1b51850b4acf21b179c45070ac7b03a9
LITECOIN_MERKLE_HASH=999ad67d669569e6168d11f92cd4ee8a056a2a5754253164ec8fb9593f923267
LITECOIN_MAIN_GENESIS_HASH=0000093e6f9d658353d8def21d98a5a5126a388a7c5987bce7cac4ccf5299dd0
LITECOIN_TEST_GENESIS_HASH=00000ba049e5c1f95474ea3fc62d5f1b1632a294c20c22fea701134a43cf3068
LITECOIN_REGTEST_GENESIS_HASH=000005ec6d48ac579d697448a82e93127b94403770629399cf561caa216a694b
MINIMUM_CHAIN_WORK_MAIN=0x00
MINIMUM_CHAIN_WORK_TEST=0x00
COIN_NAME_LOWER=$(echo $COIN_NAME | tr '[:upper:]' '[:lower:]')
COIN_NAME_UPPER=$(echo $COIN_NAME | tr '[:lower:]' '[:upper:]')
DIRNAME=$(dirname $0)
DOCKER_NETWORK="172.18.0"
DOCKER_IMAGE_LABEL="newcoin-env"
OSVERSION="$(uname -s)"

docker_build_image()
{
    IMAGE=$(docker images -q $DOCKER_IMAGE_LABEL)
    if [ -z $IMAGE ]; then
        echo Building docker image
        if [ ! -f $DOCKER_IMAGE_LABEL/Dockerfile ]; then
            mkdir -p $DOCKER_IMAGE_LABEL
            cat <<EOF > $DOCKER_IMAGE_LABEL/Dockerfile
FROM ubuntu:16.04
RUN echo deb http://ppa.launchpad.net/bitcoin/bitcoin/ubuntu xenial main >> /etc/apt/sources.list
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv D46F45428842CE5E
RUN apt-get update
RUN apt-get -y install ccache curl g++-multilib git-core pkg-config autoconf faketime bsdmainutils binutils-gold ca-certificates python git libboost-system1.58.0 libboost-filesystem1.58.0 libboost-program-options1.58.0 libboost-thread1.58.0 libboost-chrono1.58.0 libssl1.0.0 libevent-pthreads-2.0-5 libevent-2.0-5 build-essential libtool autotools-dev automake libssl-dev libevent-dev libboost-system-dev libboost-filesystem-dev libboost-chrono-dev libboost-program-options-dev libboost-test-dev libboost-thread-dev libdb4.8-dev libdb4.8++-dev libminiupnpc-dev libzmq3-dev libqt5gui5 libqt5core5a libqt5dbus5 qttools5-dev qttools5-dev-tools libprotobuf-dev protobuf-compiler libqrencode-dev python-pip
RUN pip install construct==2.5.2 X15 
EOF
        fi 
        docker build --label $DOCKER_IMAGE_LABEL --tag $DOCKER_IMAGE_LABEL $DIRNAME/$DOCKER_IMAGE_LABEL/
    else
        echo Docker image already built
    fi
}

docker_run_genesis()
{
    mkdir -p $DIRNAME/.ccache
    docker run -v $DIRNAME/GenesisH0:/GenesisH0 $DOCKER_IMAGE_LABEL /bin/bash -c "$1"
}

docker_run()
{
    mkdir -p $DIRNAME/.ccache
    docker run -v $DIRNAME/GenesisH0:/GenesisH0 -v $DIRNAME/.ccache:/root/.ccache -v $DIRNAME/$COIN_NAME_LOWER:/$COIN_NAME_LOWER $DOCKER_IMAGE_LABEL /bin/bash -c "$1"
}

docker_stop_nodes()
{
    echo "Stopping all docker nodes"
    for id in $(docker ps -q -a  -f ancestor=$DOCKER_IMAGE_LABEL); do
        docker stop $id
    done
}

docker_remove_nodes()
{
    echo "Removing all docker nodes"
    for id in $(docker ps -q -a  -f ancestor=$DOCKER_IMAGE_LABEL); do
        docker rm $id
    done
}

docker_create_network()
{
    echo "Creating docker network"
    if ! docker network inspect newcoin &>/dev/null; then
        docker network create --subnet=$DOCKER_NETWORK.0/16 newcoin
    fi
}

docker_remove_network()
{
    echo "Removing docker network"
    docker network rm newcoin
}

docker_run_node()
{
    local NODE_NUMBER=$1
    local NODE_COMMAND=$2
    mkdir -p $DIRNAME/miner${NODE_NUMBER}
    if [ ! -f $DIRNAME/miner${NODE_NUMBER}/$COIN_NAME_LOWER.conf ]; then
        cat <<EOF > $DIRNAME/miner${NODE_NUMBER}/$COIN_NAME_LOWER.conf
rpcuser=${COIN_NAME_LOWER}rpc
rpcpassword=$(cat /dev/urandom | env LC_CTYPE=C tr -dc a-zA-Z0-9 | head -c 32; echo)
EOF
    fi

    docker run --net newcoin --ip $DOCKER_NETWORK.${NODE_NUMBER} -v $DIRNAME/miner${NODE_NUMBER}:/root/.$COIN_NAME_LOWER -v $DIRNAME/$COIN_NAME_LOWER:/$COIN_NAME_LOWER $DOCKER_IMAGE_LABEL /bin/bash -c "$NODE_COMMAND"
}

generate_genesis_block()
{
    if [ ! -d GenesisH0 ]; then
        git clone $GENESISHZERO_REPOS
        pushd GenesisH0
    else
        pushd GenesisH0
        git pull
    fi

    if [ ! -f ${COIN_NAME}-main.txt ]; then
        echo "Mining genesis block... this procedure can take many hours of cpu work.."
        docker_run_genesis "python /GenesisH0/genesis.py -a scrypt -z \"$PHRASE\" -p $GENESIS_REWARD_PUBKEY 2>&1 | tee /GenesisH0/${COIN_NAME}-main.txt"
    else
        echo "Genesis block already mined.."
        cat ${COIN_NAME}-main.txt
    fi

    if [ ! -f ${COIN_NAME}-test.txt ]; then
        echo "Mining genesis block of test network... this procedure can take many hours of cpu work.."
        docker_run_genesis "python /GenesisH0/genesis.py  -t 1486949366 -a scrypt -z \"$PHRASE\" -p $GENESIS_REWARD_PUBKEY 2>&1 | tee /GenesisH0/${COIN_NAME}-test.txt"
    else
        echo "Genesis block already mined.."
        cat ${COIN_NAME}-test.txt
    fi

    if [ ! -f ${COIN_NAME}-regtest.txt ]; then
        echo "Mining genesis block of regtest network... this procedure can take many hours of cpu work.."
        docker_run_genesis "python /GenesisH0/genesis.py -t 1296688602 -b 0x207fffff -n 0 -a scrypt -z \"$PHRASE\" -p $GENESIS_REWARD_PUBKEY 2>&1 | tee /GenesisH0/${COIN_NAME}-regtest.txt"
    else
        echo "Genesis block already mined.."
        cat ${COIN_NAME}-regtest.txt
    fi

    MAIN_PUB_KEY=$(cat ${COIN_NAME}-main.txt | grep "^pubkey:" | $SED 's/^pubkey: //')
    MERKLE_HASH=$(cat ${COIN_NAME}-main.txt | grep "^merkle hash:" | $SED 's/^merkle hash: //')
    TIMESTAMP=$(cat ${COIN_NAME}-main.txt | grep "^time:" | $SED 's/^time: //')
    BITS=$(cat ${COIN_NAME}-main.txt | grep "^bits:" | $SED 's/^bits: //')

    MAIN_NONCE=$(cat ${COIN_NAME}-main.txt | grep "^nonce:" | $SED 's/^nonce: //')
    TEST_NONCE=$(cat ${COIN_NAME}-test.txt | grep "^nonce:" | $SED 's/^nonce: //')
    REGTEST_NONCE=$(cat ${COIN_NAME}-regtest.txt | grep "^nonce:" | $SED 's/^nonce: //')

    MAIN_GENESIS_HASH=$(cat ${COIN_NAME}-main.txt | grep "^genesis hash:" | $SED 's/^genesis hash: //')
    TEST_GENESIS_HASH=$(cat ${COIN_NAME}-test.txt | grep "^genesis hash:" | $SED 's/^genesis hash: //')
    REGTEST_GENESIS_HASH=$(cat ${COIN_NAME}-regtest.txt | grep "^genesis hash:" | $SED 's/^genesis hash: //')

    popd
}

newcoin_replace_vars()
{
    if [ -d $COIN_NAME_LOWER ]; then
        echo "Warning: $COIN_NAME_LOWER already existing. Not replacing any values"
        return 0
    fi
    if [ ! -d "litecoin-master" ]; then
        # clone litecoin and keep local cache
        git clone -b $LITECOIN_BRANCH $LITECOIN_REPOS litecoin-master
    else
        echo "Updating master branch"
        pushd litecoin-master
        git pull
        popd
    fi

    git clone -b $LITECOIN_BRANCH litecoin-master $COIN_NAME_LOWER

    pushd $COIN_NAME_LOWER

    # first rename all directories
    for i in $(find . -type d | grep -v "^./.git" | grep litecoin); do 
        git mv $i $(echo $i| $SED "s/litecoin/$COIN_NAME_LOWER/")
    done

    # then rename all files
    for i in $(find . -type f | grep -v "^./.git" | grep litecoin); do
        git mv $i $(echo $i| $SED "s/litecoin/$COIN_NAME_LOWER/")
    done

    # now replace all litecoin references to the new coin name
    for i in $(find . -type f | grep -v "^./.git"); do
        $SED -i "s/Sovcoin/$COIN_NAME/g" $i
        $SED -i "s/sovcoin/$COIN_NAME_LOWER/g" $i
        $SED -i "s/SOVCOIN/$COIN_NAME_UPPER/g" $i
        $SED -i "s/SovCoinX/minblock/g" $i
    done

    $SED -i "s/21000000/$TOTAL_SUPPLY/" src/amount.h
    $SED -i "s/1,63/1,$PUBKEY_CHAR/" src/chainparams.cpp

    $SED -i "s/1530264182/$TIMESTAMP/" src/chainparams.cpp

    $SED -i "s;SOV Coin;$PHRASE;" src/chainparams.cpp

    $SED -i "s/= 11888;/= $MAINNET_PORT;/" src/chainparams.cpp
    $SED -i "s/= 17979;/= $TESTNET_PORT;/" src/chainparams.cpp

    $SED -i "s/$LITECOIN_PUB_KEY/$MAIN_PUB_KEY/" src/chainparams.cpp
    $SED -i "s/$LITECOIN_MERKLE_HASH/$MERKLE_HASH/" src/chainparams.cpp
    $SED -i "s/$LITECOIN_MERKLE_HASH/$MERKLE_HASH/" src/qt/test/rpcnestedtests.cpp

    $SED -i "0,/$LITECOIN_MAIN_GENESIS_HASH/s//$MAIN_GENESIS_HASH/" src/chainparams.cpp
    $SED -i "0,/$LITECOIN_TEST_GENESIS_HASH/s//$TEST_GENESIS_HASH/" src/chainparams.cpp
    $SED -i "0,/$LITECOIN_REGTEST_GENESIS_HASH/s//$REGTEST_GENESIS_HASH/" src/chainparams.cpp

    $SED -i "0,/2084524493/s//$MAIN_NONCE/" src/chainparams.cpp
    $SED -i "0,/293345/s//$TEST_NONCE/" src/chainparams.cpp
    $SED -i "0,/1296688602, 0/s//1296688602, $REGTEST_NONCE/" src/chainparams.cpp
    $SED -i "0,/0x1e0ffff0/s//$BITS/" src/chainparams.cpp

    $SED -i "s,vSeeds.push_back,//vSeeds.push_back,g" src/chainparams.cpp

    if [ -n "$PREMINED_AMOUNT" ]; then
        $SED -i "s/CAmount nSubsidy = 50 \* COIN;/if \(nHeight == 1\) return COIN \* $PREMINED_AMOUNT;\n    CAmount nSubsidy = 50 \* COIN;/" src/validation.cpp
    fi

    $SED -i "s/COINBASE_MATURITY = 100/COINBASE_MATURITY = $COINBASE_MATURITY/" src/consensus/consensus.h

    # reset minimum chain work to 0
    $SED -i "s/$MINIMUM_CHAIN_WORK_MAIN/0x00/" src/chainparams.cpp
    $SED -i "s/$MINIMUM_CHAIN_WORK_TEST/0x00/" src/chainparams.cpp

    # change bip activation heights
    # bip 34
    $SED -i "s/710000/0/" src/chainparams.cpp
    # bip 65
    $SED -i "s/918684/0/" src/chainparams.cpp
    # bip 66
    $SED -i "s/811879/0/" src/chainparams.cpp

    # TODO: fix checkpoints
    popd
}

build_new_coin()
{
    # only run autogen.sh/configure if not done previously
    if [ ! -e $COIN_NAME_LOWER/Makefile ]; then
        docker_run "cd /$COIN_NAME_LOWER ; bash  /$COIN_NAME_LOWER/autogen.sh"
        docker_run "cd /$COIN_NAME_LOWER ; bash  /$COIN_NAME_LOWER/configure"
    fi
    # always build as the user could have manually changed some files
    docker_run "cd /$COIN_NAME_LOWER ; make -j12"
}


if [ $DIRNAME =  "." ]; then
    DIRNAME=$PWD
fi

cd $DIRNAME

# sanity check

case $OSVERSION in
    Linux*)
        SED=sed
    ;;
    Darwin*)
        SED=$(which gsed 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo "please install gnu-sed with 'brew install gnu-sed'"
            exit 1
        fi
        SED=gsed
    ;;
    *)
        echo "This script only works on Linux and MacOS"
        exit 1
    ;;
esac


if ! which docker &>/dev/null; then
    echo Please install docker first
    exit 1
fi

if ! which git &>/dev/null; then
    echo Please install git first
    exit 1
fi

case $1 in
    stop)
        docker_stop_nodes
    ;;
    remove_nodes)
        docker_stop_nodes
        docker_remove_nodes
    ;;
    clean_up)
        docker_stop_nodes
        for i in $(seq 2 5); do
           docker_run_node $i "rm -rf /$COIN_NAME_LOWER /root/.$COIN_NAME_LOWER" &>/dev/null
        done
        docker_remove_nodes
        docker_remove_network
        rm -rf $COIN_NAME_LOWER
        if [ "$2" != "keep_genesis_block" ]; then
            rm -f GenesisH0/${COIN_NAME}-*.txt
        fi
        for i in $(seq 2 5); do
           rm -rf miner$i
        done
    ;;
    start)
        if [ -n "$(docker ps -q -f ancestor=$DOCKER_IMAGE_LABEL)" ]; then
            echo "There are nodes running. Please stop them first with: $0 stop"
            exit 1
        fi
        docker_build_image
        generate_genesis_block
        newcoin_replace_vars
        build_new_coin
        docker_create_network

        docker_run_node 2 "cd /$COIN_NAME_LOWER ; ./src/${COIN_NAME_LOWER}d $CHAIN -listen -noconnect -bind=$DOCKER_NETWORK.2 -addnode=$DOCKER_NETWORK.1 -addnode=$DOCKER_NETWORK.3 -addnode=$DOCKER_NETWORK.4 -addnode=$DOCKER_NETWORK.5" &
        docker_run_node 3 "cd /$COIN_NAME_LOWER ; ./src/${COIN_NAME_LOWER}d $CHAIN -listen -noconnect -bind=$DOCKER_NETWORK.3 -addnode=$DOCKER_NETWORK.1 -addnode=$DOCKER_NETWORK.2 -addnode=$DOCKER_NETWORK.4 -addnode=$DOCKER_NETWORK.5" &
        docker_run_node 4 "cd /$COIN_NAME_LOWER ; ./src/${COIN_NAME_LOWER}d $CHAIN -listen -noconnect -bind=$DOCKER_NETWORK.4 -addnode=$DOCKER_NETWORK.1 -addnode=$DOCKER_NETWORK.2 -addnode=$DOCKER_NETWORK.3 -addnode=$DOCKER_NETWORK.5" &
        docker_run_node 5 "cd /$COIN_NAME_LOWER ; ./src/${COIN_NAME_LOWER}d $CHAIN -listen -noconnect -bind=$DOCKER_NETWORK.5 -addnode=$DOCKER_NETWORK.1 -addnode=$DOCKER_NETWORK.2 -addnode=$DOCKER_NETWORK.3 -addnode=$DOCKER_NETWORK.4" &

        echo "Docker containers should be up and running now. You may run the following command to check the network status:
for i in \$(docker ps -q); do docker exec \$i /$COIN_NAME_LOWER/src/${COIN_NAME_LOWER}-cli $CHAIN getinfo; done"
        echo "To ask the nodes to mine some blocks simply run:
for i in \$(docker ps -q); do docker exec \$i /$COIN_NAME_LOWER/src/${COIN_NAME_LOWER}-cli $CHAIN generate 2  & done"
        exit 1
    ;;
    *)
        cat <<EOF
Usage: $0 (start|stop|remove_nodes|clean_up)
 - start: bootstrap environment, build and run your new coin
 - stop: simply stop the containers without removing them
 - remove_nodes: remove the old docker container images. This will stop them first if necessary.
 - clean_up: WARNING: this will stop and remove docker containers and network, source code, genesis block information and nodes data directory. (to start from scratch)
EOF
    ;;
esac
