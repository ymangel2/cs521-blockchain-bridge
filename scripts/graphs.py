import matplotlib.pyplot as plt
plt.style.use('seaborn-v0_8')
N = [1,2,5,10,25,50,100]
throughput = [0.061155,0.115009,0.153567,0.233825,0.366816,0.506186,0.729496]

# Ideal linear scaling based on N=1
baseline = throughput[0]
ideal = [baseline * n for n in N]

plt.figure()
plt.plot(N, throughput, marker='o', label="Actual")
# plt.plot(N, ideal, linestyle='--', label="Ideal (linear scaling)")

plt.xlabel("Concurrency (N)")
plt.ylabel("Jobs/sec")
plt.title("Throughput vs Concurrency")
plt.legend()
plt.grid()
plt.show()

efficiency = [t / i for t, i in zip(throughput, ideal)]

plt.figure()
plt.plot(N, efficiency, marker='o')

plt.xlabel("Concurrency (N)")
plt.ylabel("Efficiency (Actual / Ideal)")
plt.title("Scaling Efficiency")
plt.grid()
plt.show()

lock_mint = [8168,7145,12239,14097,19348,25459,35966]
burn_redeem = [8139,7668,12168,14029,20151,27474,33654]

plt.figure()
plt.plot(N, lock_mint, marker='o', label="Lock + Mint")
plt.plot(N, burn_redeem, marker='o', label="Burn + Redeem")

plt.xlabel("Concurrency (N)")
plt.ylabel("Latency (ms)")
plt.title("Per-Lane Latency vs Concurrency")
plt.legend()
plt.grid()
plt.show()

lock_mint_gas = [112468,103918,98780,97066,96132,95700,95533]
burn_release_gas = [78237,80643,82096,82567,82863,82957,83005]

plt.figure()
plt.plot(N, lock_mint_gas, marker='o', label="Lock + Mint Gas")
plt.plot(N, burn_release_gas, marker='o', label="Burn + Release Gas")

plt.xlabel("Concurrency (N)")
plt.ylabel("Gas")
plt.title("Average Gas Usage vs Concurrency")
plt.legend()
plt.grid()
plt.show()

deposit = [4090,4089,4110,4123,4151,4227,4532]
mint = [8121,8197,16332,21440,34601,46827,71631]
burn = [12275,12293,20373,25559,38768,47004,72006]
release = [16352,17390,32559,42767,68154,98778,137081]

plt.style.use('seaborn-v0_8')

plt.figure(figsize=(8,5))

plt.plot(N, deposit, marker='o', label="Deposit")
plt.plot(N, mint, marker='o', label="Mint")
plt.plot(N, burn, marker='o', label="Burn")
plt.plot(N, release, marker='o', label="Release")

plt.xlabel("Concurrency (N)")
plt.ylabel("Segment Time (ms)")
plt.title("Segment Times vs Concurrency")
plt.legend()
plt.grid(True)

plt.tight_layout()
plt.show()