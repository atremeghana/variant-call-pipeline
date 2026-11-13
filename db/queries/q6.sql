-- For each run, how many samples of each sex?
SELECT rs.run_id,
       s.sex,
       COUNT(*) AS n_samples
FROM run_samples rs
JOIN samples s ON s.sample_id = rs.sample_id
GROUP BY rs.run_id, s.sex;
